class_name EmptyState
extends CenterContainer

## What an empty panel says: an icon, ONE sentence that names the next step,
## and optionally the button that takes it. A blank panel reads as broken
## (the work planner with no people, the SCAD store before a part is picked,
## a "Selected part" card before a click).
##
##   body.add_child(EmptyState.make("users", "No people on this site yet.",
##       "Open festival mode", _open_festival))
##   card.add_child(EmptyState.row("mouse-pointer-click", "Click a part in the view to edit it."))
##
## `make` fills and centres in whatever space it is given; `row` is the
## compact form for inside a card or a column (icon left, text wrapping).

const TEXT_W := 380.0

var _label: Label = null
var _button: Button = null


static func make(icon: String, text: String, button_text: String = "",
		on_press: Callable = Callable()) -> EmptyState:
	var e := EmptyState.new()
	e.name = "EmptyState"
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	e.size_flags_vertical = Control.SIZE_EXPAND_FILL
	e.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", UITheme.SPACE_SM)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	e.add_child(v)
	if not icon.is_empty():
		var ic := TextureRect.new()
		ic.texture = UiIcons.icon(icon, 32)
		ic.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		ic.modulate = UITheme.C_TEXT_M
		ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		v.add_child(ic)
	e._label = Label.new()
	e._label.text = text
	e._label.custom_minimum_size.x = TEXT_W
	e._label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	e._label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	e._label.add_theme_font_size_override("font_size", UITheme.FONT_MD)
	e._label.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	e._label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(e._label)
	if not button_text.is_empty():
		e._button = Button.new()
		e._button.text = button_text
		e._button.focus_mode = Control.FOCUS_NONE
		e._button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		UITheme.style_button(e._button)
		if on_press.is_valid():
			e._button.pressed.connect(on_press)
		v.add_child(e._button)
	return e


## The compact form: a muted icon and one wrapping sentence, for a card.
static func row(icon: String, text: String) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.name = "EmptyState"
	h.add_theme_constant_override("separation", UITheme.SPACE_SM)
	h.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if not icon.is_empty():
		var ic := TextureRect.new()
		ic.texture = UiIcons.icon(icon, 16)
		ic.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		ic.modulate = UITheme.C_TEXT_M
		ic.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		ic.custom_minimum_size = Vector2(18, 18)
		h.add_child(ic)
	var l := Label.new()
	l.text = text
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	l.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	h.add_child(l)
	return h


func set_text(text: String) -> void:
	if _label != null:
		_label.text = text
