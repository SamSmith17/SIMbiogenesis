class_name UiThemeBuilder
extends RefCounted

## Builds the project's Godot `Theme` from UITheme's palette, spacing and font
## scale, and installs it (plus the UI scale) on the root window — so every
## Control that is not explicitly overridden, including Godot's stock dialogs,
## tabs, option-button popups, scrollbars, tooltips and spin boxes, is styled
## the same way. Before this there was no Theme at all and every control was
## styled by hand (or rendered in the grey engine default).
##
## The existing `UITheme.style_*` helpers keep working: they are per-control
## overrides on top of this base.

const FONT_DIR := "res://assets/fonts/inter/"
## Default size for text no script sizes explicitly.
const BASE_FONT_SIZE := 15

static var _theme: Theme = null
static var _fonts: Dictionary = {}


## Inter at a weight: "regular" | "medium" | "semibold". Falls back to the
## engine default when the font files are missing (a stripped export).
static func font(weight: String = "regular") -> Font:
	if _fonts.has(weight):
		return _fonts[weight]
	var file := {"regular": "Inter-Regular.ttf", "medium": "Inter-Medium.ttf",
		"semibold": "Inter-SemiBold.ttf"}.get(weight, "Inter-Regular.ttf") as String
	var f: Font = null
	if ResourceLoader.exists(FONT_DIR + file):
		f = load(FONT_DIR + file) as Font
	_fonts[weight] = f
	return f


## Inter with tabular figures: every digit the same width, so a changing
## readout ("1.98 kW" → "2.04 kW") does not shuffle the text beside it.
static func numeric_font(weight: String = "medium") -> Font:
	var key := "num_" + weight
	if _fonts.has(key):
		return _fonts[key]
	var base := font(weight)
	var out: Font = base
	if base != null:
		var fv := FontVariation.new()
		fv.base_font = base
		var ts := TextServerManager.get_primary_interface()
		fv.opentype_features = {ts.name_to_tag("tnum"): 1}
		out = fv
	_fonts[key] = out
	return out


static func build() -> Theme:
	if _theme != null:
		return _theme
	var t := Theme.new()
	var reg := font("regular")
	if reg != null:
		t.default_font = reg
	t.default_font_size = BASE_FONT_SIZE

	# --- shared boxes ----------------------------------------------------------
	var panel := UITheme.panel_style()
	var raised := UITheme.card_style()
	var empty := StyleBoxEmpty.new()
	var focus := _box(Color(0, 0, 0, 0), UITheme.C_PRIMARY, 1, UITheme.CORNER_RADIUS)
	focus.draw_center = false
	var field := _box(Color(UITheme.C_BG, 0.75), UITheme.C_BORDER, 1, 4, 6, 4)
	var field_focus := _box(Color(UITheme.C_BG, 0.85), UITheme.C_PRIMARY, 1, 4, 6, 4)
	var field_ro := _box(Color(UITheme.C_BG, 0.35), Color(UITheme.C_BORDER, 0.5), 1, 4, 6, 4)

	# --- Label / RichTextLabel --------------------------------------------------
	t.set_color("font_color", "Label", UITheme.C_TEXT)
	t.set_color("font_shadow_color", "Label", Color(0, 0, 0, 0))
	t.set_color("default_color", "RichTextLabel", UITheme.C_TEXT)

	# --- Buttons ------------------------------------------------------------------
	for cls in ["Button", "OptionButton", "MenuButton", "CheckBox", "CheckButton", "LinkButton"]:
		t.set_color("font_color", cls, UITheme.C_TEXT)
		t.set_color("font_hover_color", cls, UITheme.C_TEXT)
		t.set_color("font_pressed_color", cls, UITheme.C_TEXT)
		t.set_color("font_hover_pressed_color", cls, UITheme.C_TEXT)
		t.set_color("font_focus_color", cls, UITheme.C_TEXT)
		t.set_color("font_disabled_color", cls, UITheme.C_TEXT_M)
		t.set_color("icon_normal_color", cls, UITheme.C_TEXT_S)
		t.set_color("icon_hover_color", cls, UITheme.C_TEXT)
		t.set_color("icon_pressed_color", cls, UITheme.C_PRIMARY)
		t.set_color("icon_disabled_color", cls, UITheme.C_TEXT_M)
		t.set_constant("h_separation", cls, 6)
	for cls in ["Button", "OptionButton", "MenuButton"]:
		t.set_stylebox("normal", cls, UITheme.button_style("normal"))
		t.set_stylebox("hover", cls, UITheme.button_style("hover"))
		t.set_stylebox("pressed", cls, UITheme.button_style("pressed"))
		t.set_stylebox("hover_pressed", cls, UITheme.button_style("pressed"))
		var dis := UITheme.button_style("normal")
		dis.bg_color = Color(UITheme.C_PANEL, 0.5)
		dis.border_color = Color(UITheme.C_BORDER, 0.45)
		t.set_stylebox("disabled", cls, dis)
		t.set_stylebox("focus", cls, focus)
	# MenuButtons are toolbar menus: flat until hovered.
	t.set_stylebox("normal", "MenuButton", _box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0, UITheme.CORNER_RADIUS, 10, 6))
	for cls in ["CheckBox", "CheckButton"]:
		for s in ["normal", "pressed", "hover", "hover_pressed", "disabled"]:
			t.set_stylebox(s, cls, empty)
		t.set_stylebox("focus", cls, empty)
	# Godot's default check glyphs are a dark square on a dark panel — an
	# unchecked box was nearly invisible (graph Display settings, 2026-10-14).
	t.set_icon("unchecked", "CheckBox", _check_icon(false))
	t.set_icon("checked", "CheckBox", _check_icon(true))
	t.set_icon("unchecked_disabled", "CheckBox", _check_icon(false, true))
	t.set_icon("checked_disabled", "CheckBox", _check_icon(true, true))
	t.set_color("font_color", "LinkButton", UITheme.C_PRIMARY)

	# --- Text fields -----------------------------------------------------------
	for cls in ["LineEdit", "TextEdit", "CodeEdit"]:
		t.set_stylebox("normal", cls, field)
		t.set_stylebox("focus", cls, field_focus)
		t.set_stylebox("read_only", cls, field_ro)
		t.set_color("font_color", cls, UITheme.C_TEXT)
		t.set_color("font_placeholder_color", cls, UITheme.C_TEXT_M)
		t.set_color("font_uneditable_color", cls, UITheme.C_TEXT_S)
		t.set_color("caret_color", cls, UITheme.C_PRIMARY)
		t.set_color("selection_color", cls, Color(UITheme.C_PRIMARY, 0.35))
	var num := numeric_font("regular")
	if num != null:
		t.set_font("font", "LineEdit", num)
		t.set_font("font", "SpinBox", num)

	# --- Popups / menus / tooltips -------------------------------------------------
	var popup := _box(UITheme.C_PANEL_RAISED, UITheme.C_BORDER, 1, UITheme.CORNER_RADIUS, 6, 6)
	popup.shadow_color = Color(0, 0, 0, 0.45)
	popup.shadow_size = 8
	t.set_stylebox("panel", "PopupMenu", popup)
	t.set_stylebox("hover", "PopupMenu", _box(Color(UITheme.C_PRIMARY, 0.20), Color(0, 0, 0, 0), 0, 4))
	t.set_color("font_color", "PopupMenu", UITheme.C_TEXT)
	t.set_color("font_hover_color", "PopupMenu", UITheme.C_TEXT)
	t.set_color("font_disabled_color", "PopupMenu", UITheme.C_TEXT_M)
	t.set_color("font_separator_color", "PopupMenu", UITheme.C_TEXT_S)
	t.set_constant("v_separation", "PopupMenu", 6)
	t.set_stylebox("panel", "PopupPanel", popup)
	var tip := _box(UITheme.C_PANEL_RAISED, UITheme.C_BORDER, 1, 4, 8, 6)
	t.set_stylebox("panel", "TooltipPanel", tip)
	t.set_color("font_color", "TooltipLabel", UITheme.C_TEXT)
	t.set_font_size("font_size", "TooltipLabel", UITheme.FONT_SM)

	# --- Containers ------------------------------------------------------------
	t.set_stylebox("panel", "PanelContainer", panel)
	t.set_stylebox("panel", "Panel", panel)
	var tab_sel := _box(UITheme.C_PANEL_RAISED, UITheme.C_BORDER, 0, 4, 12, 6)
	tab_sel.border_width_bottom = 2
	tab_sel.border_color = UITheme.C_PRIMARY
	var tab_un := _box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0, 4, 12, 6)
	var tab_hov := _box(Color(UITheme.C_PANEL_RAISED, 0.6), Color(0, 0, 0, 0), 0, 4, 12, 6)
	for cls in ["TabContainer", "TabBar"]:
		t.set_stylebox("tab_selected", cls, tab_sel)
		t.set_stylebox("tab_unselected", cls, tab_un)
		t.set_stylebox("tab_hovered", cls, tab_hov)
		t.set_stylebox("tab_disabled", cls, tab_un)
		t.set_stylebox("tab_focus", cls, focus)
		t.set_color("font_selected_color", cls, UITheme.C_TEXT)
		t.set_color("font_unselected_color", cls, UITheme.C_TEXT_S)
		t.set_color("font_hovered_color", cls, UITheme.C_TEXT)
		t.set_color("font_disabled_color", cls, UITheme.C_TEXT_M)
	t.set_stylebox("panel", "TabContainer", _box(UITheme.C_PANEL, UITheme.C_BORDER, 1, UITheme.CORNER_RADIUS, UITheme.SPACE_MD, UITheme.SPACE_MD))
	t.set_stylebox("tabbar_background", "TabContainer", empty)
	t.set_stylebox("panel", "ItemList", field)
	t.set_stylebox("focus", "ItemList", empty)
	t.set_stylebox("selected", "ItemList", _box(Color(UITheme.C_PRIMARY, 0.22), Color(0, 0, 0, 0), 0, 4))
	t.set_stylebox("selected_focus", "ItemList", _box(Color(UITheme.C_PRIMARY, 0.30), Color(0, 0, 0, 0), 0, 4))
	t.set_stylebox("hovered", "ItemList", _box(Color(UITheme.C_PANEL_RAISED, 0.8), Color(0, 0, 0, 0), 0, 4))
	t.set_color("font_color", "ItemList", UITheme.C_TEXT_S)
	t.set_color("font_selected_color", "ItemList", UITheme.C_TEXT)
	t.set_color("font_hovered_color", "ItemList", UITheme.C_TEXT)
	t.set_stylebox("panel", "Tree", field)
	t.set_color("font_color", "Tree", UITheme.C_TEXT_S)
	t.set_color("font_selected_color", "Tree", UITheme.C_TEXT)

	# --- Scrollbars: slim, quiet until touched -----------------------------------
	for cls in ["VScrollBar", "HScrollBar"]:
		t.set_stylebox("scroll", cls, _box(Color(UITheme.C_BG, 0.35), Color(0, 0, 0, 0), 0, 4, 3, 3))
		t.set_stylebox("scroll_focus", cls, _box(Color(UITheme.C_BG, 0.35), Color(0, 0, 0, 0), 0, 4, 3, 3))
		t.set_stylebox("grabber", cls, _box(Color(UITheme.C_BORDER, 0.9), Color(0, 0, 0, 0), 0, 4, 3, 3))
		t.set_stylebox("grabber_highlight", cls, _box(Color(UITheme.C_TEXT_S, 0.9), Color(0, 0, 0, 0), 0, 4, 3, 3))
		t.set_stylebox("grabber_pressed", cls, _box(UITheme.C_PRIMARY, Color(0, 0, 0, 0), 0, 4, 3, 3))

	# --- Range controls ----------------------------------------------------------
	var bar_bg := _box(Color(UITheme.C_BG, 0.75), Color(UITheme.C_BORDER, 0.8), 1, 3)
	t.set_stylebox("background", "ProgressBar", bar_bg)
	t.set_stylebox("fill", "ProgressBar", _box(UITheme.C_PRIMARY, Color(0, 0, 0, 0), 0, 3))
	t.set_color("font_color", "ProgressBar", UITheme.C_TEXT)
	for cls in ["HSlider", "VSlider"]:
		var track := _box(Color(UITheme.C_BG, 0.85), Color(UITheme.C_BORDER, 0.8), 1, 3)
		track.content_margin_top = 2
		track.content_margin_bottom = 2
		t.set_stylebox("slider", cls, track)
		t.set_stylebox("grabber_area", cls, _box(Color(UITheme.C_PRIMARY, 0.7), Color(0, 0, 0, 0), 0, 3))
		t.set_stylebox("grabber_area_highlight", cls, _box(UITheme.C_PRIMARY, Color(0, 0, 0, 0), 0, 3))

	# --- Collapsible sections (FoldableContainer; scenes/ui/kit/collapsible.gd) --
	# A quiet title row: no box, a hover tint, a Lucide chevron, small
	# semibold text. The body gets no frame — the section sits in whatever
	# card or dock holds it.
	var fold_title := _box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0, 4, 4, 4)
	var fold_hover := _box(Color(UITheme.C_PANEL_RAISED, 0.7), Color(0, 0, 0, 0), 0, 4, 4, 4)
	t.set_stylebox("title_panel", "FoldableContainer", fold_title)
	t.set_stylebox("title_hover_panel", "FoldableContainer", fold_hover)
	t.set_stylebox("title_collapsed_panel", "FoldableContainer", fold_title)
	t.set_stylebox("title_collapsed_hover_panel", "FoldableContainer", fold_hover)
	t.set_stylebox("panel", "FoldableContainer", _box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0, 0, 0, 4))
	t.set_stylebox("focus", "FoldableContainer", empty)
	t.set_icon("expanded_arrow", "FoldableContainer", UiIcons.icon("chevron-down", 14))
	t.set_icon("expanded_arrow_mirrored", "FoldableContainer", UiIcons.icon("chevron-down", 14))
	t.set_icon("folded_arrow", "FoldableContainer", UiIcons.icon("chevron-right", 14))
	t.set_icon("folded_arrow_mirrored", "FoldableContainer", UiIcons.icon("chevron-left", 14))
	t.set_color("font_color", "FoldableContainer", UITheme.C_TEXT)
	t.set_color("hover_font_color", "FoldableContainer", UITheme.C_TEXT)
	t.set_color("collapsed_font_color", "FoldableContainer", UITheme.C_TEXT_S)
	var semi := font("semibold")
	if semi != null:
		t.set_font("font", "FoldableContainer", semi)
	t.set_font_size("font_size", "FoldableContainer", UITheme.FONT_SM)
	t.set_constant("h_separation", "FoldableContainer", 6)

	# --- Separators --------------------------------------------------------------
	var line := StyleBoxLine.new()
	line.color = Color(UITheme.C_BORDER, 0.7)
	line.thickness = 1
	t.set_stylebox("separator", "HSeparator", line)
	var vline := StyleBoxLine.new()
	vline.color = Color(UITheme.C_BORDER, 0.7)
	vline.thickness = 1
	vline.vertical = true
	t.set_stylebox("separator", "VSeparator", vline)

	# --- Stock dialogs / embedded windows ----------------------------------------
	var win := _box(UITheme.C_PANEL, UITheme.C_BORDER, 1, UITheme.CORNER_RADIUS, 12, 12)
	win.expand_margin_top = 28
	win.shadow_color = Color(0, 0, 0, 0.5)
	win.shadow_size = 12
	t.set_stylebox("embedded_border", "Window", win)
	t.set_stylebox("embedded_unfocused_border", "Window", win)
	t.set_color("title_color", "Window", UITheme.C_TEXT)
	t.set_stylebox("panel", "AcceptDialog", _box(UITheme.C_PANEL, Color(0, 0, 0, 0), 0, 0, 12, 12))

	_theme = t
	return t


## A 16 px checkbox glyph: an outlined rounded square, or filled primary with a
## dark tick. Drawn into an Image (no asset to ship, crisp at 1×; the canvas_items
## stretch scales it with the UI).
static func _check_icon(checked: bool, disabled: bool = false) -> ImageTexture:
	var n := 16
	var img := Image.create_empty(n, n, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var a := 0.45 if disabled else 1.0
	var edge := Color(UITheme.C_TEXT_S, 0.9 * a)
	var fill := Color(UITheme.C_PRIMARY, a)
	for y in range(1, n - 1):
		for x in range(1, n - 1):
			# Rounded corners: skip the outermost corner pixel of each corner.
			var corner := (x == 1 or x == n - 2) and (y == 1 or y == n - 2)
			if corner:
				continue
			var border := x <= 2 or y <= 2 or x >= n - 3 or y >= n - 3
			if checked:
				img.set_pixel(x, y, fill)
			elif border:
				img.set_pixel(x, y, edge)
			else:
				img.set_pixel(x, y, Color(UITheme.C_BG, 0.6 * a))
	if checked:
		var ink := Color(UITheme.C_BG, a)
		var pts := [Vector2i(4, 8), Vector2i(5, 9), Vector2i(6, 10), Vector2i(7, 11), Vector2i(8, 10),
			Vector2i(9, 9), Vector2i(10, 8), Vector2i(11, 7), Vector2i(12, 6)]
		for p: Vector2i in pts:
			img.set_pixel(p.x, p.y, ink)
			img.set_pixel(p.x, p.y - 1, ink)
	return ImageTexture.create_from_image(img)


static func _box(bg: Color, border: Color, border_w: int, radius: int,
		margin_x: int = -1, margin_y: int = -1) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(border_w)
	sb.set_corner_radius_all(radius)
	if margin_x >= 0:
		sb.content_margin_left = margin_x
		sb.content_margin_right = margin_x
	if margin_y >= 0:
		sb.content_margin_top = margin_y
		sb.content_margin_bottom = margin_y
	return sb


# ---------------------------------------------------------------------------
# Install: theme + UI scale on the root window
# ---------------------------------------------------------------------------

const PREFS_PATH := "user://ui_prefs.cfg"
## 0 = Auto. Offered in Settings → Display.
const SCALE_CHOICES := [0.0, 0.9, 1.0, 1.1, 1.25, 1.5]

static var _scale_pref := -1.0
static var _cli_scale := -1.0
static var _installed_root: Window = null


## The player's UI scale choice (0 = Auto).
static func scale_pref() -> float:
	if _scale_pref < 0.0:
		var cfg := ConfigFile.new()
		_scale_pref = float(cfg.get_value("ui", "scale", 0.0)) if cfg.load(PREFS_PATH) == OK else 0.0
	return _scale_pref


static func set_scale_pref(v: float) -> void:
	_scale_pref = maxf(v, 0.0)
	var cfg := ConfigFile.new()
	cfg.load(PREFS_PATH)
	cfg.set_value("ui", "scale", _scale_pref)
	cfg.save(PREFS_PATH)
	if _installed_root != null and is_instance_valid(_installed_root):
		_apply_scale(_installed_root)


## Auto: the canvas already scales with the window (stretch canvas_items on a
## 1920×1080 base), so text shrinks on small windows — 11 px type is ~7 px on
## a 720p screen. Auto boosts small windows back towards legible (×1.25 at
## 720p, ×1.0 at 1080p and above).
static func auto_scale(window_h: float) -> float:
	if window_h >= 1000.0:
		return 1.0
	return clampf(1.0 + (1080.0 - window_h) / 360.0 * 0.25, 1.0, 1.35)


static func effective_scale(window_h: float) -> float:
	if _cli_scale > 0.0:
		return _cli_scale
	var p := scale_pref()
	return auto_scale(window_h) if p <= 0.0 else p


## Apply theme + scale to `root` and keep the scale current as the window
## resizes. Safe to call more than once.
static func install(root: Window) -> void:
	if root == null:
		return
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--ui-scale="):
			_cli_scale = clampf(a.get_slice("=", 1).to_float(), 0.5, 3.0)
	# Theme propagation stops at non-Control parents: the HUD lives under
	# Main (Node3D) → UILayer (CanvasLayer), so a theme on the root window
	# never reaches it. Merge into the engine's DEFAULT theme instead — that is
	# the fallback every Control consults wherever it sits in the tree.
	var t := build()
	var def := ThemeDB.get_default_theme()
	if def != null and not def.has_meta("simbio_ui_theme"):
		def.merge_with(t)
		if t.default_font != null:
			def.default_font = t.default_font
			ThemeDB.fallback_font = t.default_font
		def.default_font_size = t.default_font_size
		ThemeDB.fallback_font_size = t.default_font_size
		def.set_meta("simbio_ui_theme", true)
	root.theme = t
	_installed_root = root
	_apply_scale(root)
	if not root.size_changed.is_connected(_on_root_resized):
		root.size_changed.connect(_on_root_resized)


static func _on_root_resized() -> void:
	if _installed_root != null and is_instance_valid(_installed_root):
		_apply_scale(_installed_root)


static func _apply_scale(root: Window) -> void:
	var s := effective_scale(float(root.size.y))
	if not is_equal_approx(root.content_scale_factor, s):
		root.content_scale_factor = s
