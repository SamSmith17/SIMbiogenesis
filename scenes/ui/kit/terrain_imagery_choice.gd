class_name TerrainImageryChoice
extends VBoxContainer
## "Terrain imagery" for a world whose saved imagery was made at another
## quality than this computer's: keep it as it was saved, or download it at
## this computer's quality (falling back to the saved copy when the download
## fails or there is no internet). Used by the Share window's install screen
## and the in-game world panel; TerrainImageryPlan supplies the numbers.

signal mode_chosen(mode: String)

var _saved_btn: Button = null
var _local_btn: Button = null
var _note: Label = null
var _status: Label = null
var _saved_tier := -1
var _local_tier := -1


static func create() -> TerrainImageryChoice:
	var c := TerrainImageryChoice.new()
	c._build()
	return c


## True when a world with this summary has a choice to offer.
static func has_choice(summary: Dictionary) -> bool:
	var saved := int(summary.get("saved_tier", -1))
	return saved >= 0 and saved != int(summary.get("local_tier", -1))


func _build() -> void:
	add_theme_constant_override("separation", 4)
	var hdr := Label.new()
	hdr.text = "TERRAIN IMAGERY"
	hdr.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	hdr.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	add_child(hdr)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	add_child(row)
	var group := ButtonGroup.new()
	_saved_btn = _option(row, group, "saved")
	_local_btn = _option(row, group, "local")
	_note = Label.new()
	_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_note.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_note.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	add_child(_note)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_status.add_theme_color_override("font_color", UITheme.C_WARN)
	_status.visible = false
	add_child(_status)


func _option(row: HBoxContainer, group: ButtonGroup, mode: String) -> Button:
	var b := Button.new()
	b.toggle_mode = true
	b.button_group = group
	b.focus_mode = Control.FOCUS_NONE
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	UITheme.style_button(b)
	b.toggled.connect(func(on: bool) -> void:
		if on:
			mode_chosen.emit(mode))
	row.add_child(b)
	return b


## Show a summary ({saved_tier, local_tier, mode, vram_saved, vram_local}).
func show_summary(s: Dictionary) -> void:
	_saved_tier = int(s.get("saved_tier", -1))
	_local_tier = int(s.get("local_tier", -1))
	var saved_name := TerrainImageryPlan.tier_name(_saved_tier)
	var local_name := TerrainImageryPlan.tier_name(_local_tier)
	var vs := int(s.get("vram_saved", 0))
	var vl := int(s.get("vram_local", 0))
	_saved_btn.text = "As saved (%s) · %s GPU" % [saved_name, TerrainImageryPlan.format_bytes(vs)]
	_saved_btn.tooltip_text = ("Show the imagery this world came with, exactly as it was saved. "
		+ "Loads from disk, no download.")
	var better := "sharper" if _local_tier > _saved_tier else "lighter on the GPU"
	_local_btn.text = "My quality (%s) · %s GPU" % [local_name, TerrainImageryPlan.format_bytes(vl)]
	_local_btn.tooltip_text = ("Download the imagery at this computer's quality (%s, %s). "
		% [local_name, better] + "Anything that cannot be downloaded uses the saved copy.")
	_note.text = ("Saved at %s; this computer is set to %s. Downloading needs internet; if it fails, "
		+ "the saved imagery is used, and it is never deleted.") % [saved_name, local_name]
	var mode := str(s.get("mode", "saved"))
	_saved_btn.set_pressed_no_signal(mode == "saved")
	_local_btn.set_pressed_no_signal(mode != "saved")


## A one-line warning under the buttons ("" hides it).
func set_status(text: String) -> void:
	_status.text = text
	_status.visible = not text.is_empty()
