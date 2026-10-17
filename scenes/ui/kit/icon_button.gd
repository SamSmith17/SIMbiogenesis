class_name IconButton
extends RefCounted

## The one icon button: a Lucide glyph, a hover face, a tooltip so it is never
## a mystery, and a hit target no smaller than 28 px. `close()` is THE close
## button — before the kit it was written four ways ("✕", "×", "X", "Close")
## in 29 files, in four sizes.
##
##   head.add_child(IconButton.close(close))                 # close (Esc)
##   row.add_child(IconButton.make("trash-2", "Delete style", _on_delete))
##   IconButton.as_close(existing_btn)                        # convert in place

const MIN_HIT := 28.0


## A flat icon button. `text` may be empty (icon only — then `tip` is
## required); with text it reads as an icon + label button.
static func make(icon: String, tip: String, cb: Callable = Callable(), text: String = "",
		px: int = 16) -> Button:
	var b := Button.new()
	style(b, icon, tip, text, px)
	if cb.is_valid():
		b.pressed.connect(cb)
	return b


## Style an existing Button as an icon button (keeps its signals).
static func style(b: Button, icon: String, tip: String, text: String = "", px: int = 16) -> Button:
	b.text = text
	b.icon = UiIcons.icon(icon, px)
	b.expand_icon = false
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER if text.is_empty() else HORIZONTAL_ALIGNMENT_LEFT
	b.flat = false
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(maxf(b.custom_minimum_size.x, MIN_HIT),
			maxf(b.custom_minimum_size.y, MIN_HIT))
	if not tip.is_empty():
		b.tooltip_text = tip
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0, 0, 0, 0)
	normal.set_corner_radius_all(UITheme.CORNER_RADIUS)
	normal.set_content_margin_all(5)
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(UITheme.C_PANEL_RAISED, 0.9)
	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = Color(UITheme.C_PRIMARY, 0.22)
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.add_theme_stylebox_override("disabled", normal)
	b.add_theme_color_override("icon_normal_color", UITheme.C_TEXT_S)
	b.add_theme_color_override("icon_hover_color", UITheme.C_TEXT)
	b.add_theme_color_override("icon_pressed_color", UITheme.C_PRIMARY)
	b.add_theme_color_override("icon_disabled_color", UITheme.C_TEXT_M)
	b.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	b.add_theme_color_override("font_hover_color", UITheme.C_TEXT)
	return b


## THE close button.
static func close(cb: Callable = Callable(), tip: String = "Close (Esc)") -> Button:
	return make("x", tip, cb)


## Turn an existing "✕" Button into THE close button, in place.
static func as_close(b: Button, tip: String = "Close (Esc)") -> Button:
	return style(b, "x", tip if not tip.is_empty() else b.tooltip_text)
