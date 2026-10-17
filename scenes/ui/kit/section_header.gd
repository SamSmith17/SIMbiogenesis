class_name SectionHeader
extends HBoxContainer

## The one section label: small semibold capitals in the secondary text colour
## with a hairline running to the right edge, optional icon and an optional
## right-hand note ("3 items", "live"). Replaces a dozen hand-built variants
## (cyan 11 px labels, "── TITLE ──" strings, bold BBCode lines).
##
##   parent.add_child(SectionHeader.make("Specs"))
##   parent.add_child(SectionHeader.make("Stores", "droplet", "4 tanks"))

var _label: Label = null
var _note: Label = null


static func make(title: String, icon: String = "", note: String = "") -> SectionHeader:
	var h := SectionHeader.new()
	h.add_theme_constant_override("separation", 6)
	h.custom_minimum_size.y = 26.0
	h.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if not icon.is_empty():
		var ic := TextureRect.new()
		ic.texture = UiIcons.icon(icon, 14)
		ic.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		ic.modulate = UITheme.C_TEXT_S
		ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(ic)
	h._label = Label.new()
	h._label.text = title.to_upper()
	h._label.add_theme_font_override("font", UITheme.font("semibold"))
	h._label.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	h._label.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	h._label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(h._label)
	var line := HSeparator.new()
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.modulate = Color(1, 1, 1, 0.35)
	h.add_child(line)
	h._note = Label.new()
	h._note.text = note
	h._note.visible = not note.is_empty()
	h._note.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	h._note.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	h._note.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(h._note)
	return h


func set_note(text: String) -> void:
	if _note != null:
		_note.text = text
		_note.visible = not text.is_empty()
