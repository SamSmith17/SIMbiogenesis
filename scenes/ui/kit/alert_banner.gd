class_name AlertBanner
extends PanelContainer

## The ONE look for critical state — AC off, low battery, a fault, a blocked
## need: an icon, a short line, the status colour as a tinted fill and a left
## bar. Status colours are reserved for state, so a banner is the loudest thing
## in any panel without needing capitals or emoji.
##
##   var b := AlertBanner.new()
##   b.show_alert(AlertBanner.ERROR, "AC is off — the battery is at its floor")
##   b.clear()                      # hides it
##
## Levels map onto UITheme's status colours: INFO, OK, WARN, ERROR.

enum { INFO, OK, WARN, ERROR }

const ICONS := {INFO: "info", OK: "circle-check", WARN: "triangle-alert", ERROR: "circle-alert"}

var _icon: TextureRect = null
var _label: Label = null
var _level := -1
var _text := ""


func _init() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_PASS
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	add_child(row)
	_icon = TextureRect.new()
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_icon)
	_label = Label.new()
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_label.add_theme_font_override("font", UITheme.font("semibold"))
	_label.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	row.add_child(_label)


static func color_of(level: int) -> Color:
	match level:
		OK: return UITheme.C_OK
		WARN: return UITheme.C_WARN
		ERROR: return UITheme.C_ERROR
	return UITheme.C_INFO


## Show (or update) the banner. Change-gated: calling it every frame is free.
func show_alert(level: int, text: String) -> void:
	if level == _level and text == _text and visible:
		return
	_level = level
	_text = text
	var c := color_of(level)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(c, 0.16)
	sb.border_color = c
	sb.border_width_left = 3
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 10.0
	sb.content_margin_right = 10.0
	sb.content_margin_top = 6.0
	sb.content_margin_bottom = 6.0
	add_theme_stylebox_override("panel", sb)
	_icon.texture = UiIcons.icon(str(ICONS.get(level, "info")), 16)
	_icon.modulate = c
	_label.text = text
	_label.add_theme_color_override("font_color", c.lerp(Color.WHITE, 0.25))
	visible = true


func clear() -> void:
	if visible:
		visible = false
	_level = -1
	_text = ""
