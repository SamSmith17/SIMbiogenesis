class_name KVRow
extends HBoxContainer

## One key / value line — the row every inspector, dock and card is made of.
##
## The KEY takes a fixed share of the width and ellipsizes; the VALUE takes the
## rest, ellipsizes, and shows its full text on hover. Neither can make the row
## wider than its parent, which is the property the hand-built rows lacked: one
## long key or value used to stretch a whole sidebar past the screen edge.
##
##   var row := KVRow.make("Max PV voltage", "480 V")
##   row.set_value(UiText.num(v, "V"))
##   row.set_tone(UITheme.C_WARN)        # status colour on the value only
##   var spin_row := KVRow.make_with("Charge current", spin)   # any control as value

const KEY_SHARE := 0.48

var _key: Label = null
var _value: Label = null
var _custom: Control = null


static func make(key: String, value: String = "", tip: String = "") -> KVRow:
	var r := KVRow.new()
	r._build(key, tip)
	r._value = Label.new()
	r._value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	r._value.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	r._value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r._value.size_flags_stretch_ratio = 1.0 - KEY_SHARE
	r._value.add_theme_font_override("font", UITheme.font("medium", true))
	r._value.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	r._value.add_theme_color_override("font_color", UITheme.C_TEXT)
	r._value.mouse_filter = Control.MOUSE_FILTER_PASS
	r._value.mouse_entered.connect(func() -> void: r._value.tooltip_text = r._value.text)
	r.add_child(r._value)
	r.set_value(value)
	return r


## A row whose value is a control (SpinBox, OptionButton, LineEdit…). The
## control is made shrinkable: an OptionButton stops sizing to its longest item.
static func make_with(key: String, control: Control, tip: String = "") -> KVRow:
	var r := KVRow.new()
	r._build(key, tip)
	r._custom = control
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	control.size_flags_stretch_ratio = 1.0 - KEY_SHARE
	if control is OptionButton:
		(control as OptionButton).fit_to_longest_item = false
		(control as OptionButton).clip_text = true
	r.add_child(control)
	return r


func _build(key: String, tip: String) -> void:
	add_theme_constant_override("separation", 8)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	custom_minimum_size.y = 24.0
	_key = Label.new()
	_key.text = key
	_key.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_key.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_key.size_flags_stretch_ratio = KEY_SHARE
	_key.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_key.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_key.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_key.tooltip_text = tip if not tip.is_empty() else key
	_key.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_key)


func set_value(text: String) -> void:
	if _value != null and _value.text != text:
		_value.text = text


func set_key(text: String) -> void:
	if _key != null:
		_key.text = text


## Colour the value (status only — reserve the status colours for state).
func set_tone(c: Color) -> void:
	if _value != null:
		_value.add_theme_color_override("font_color", c)


func value_control() -> Control:
	return _custom if _custom != null else _value
