class_name TutorialHud
extends Control

## Compact objective strip for the Solar Bootcamp — parented to the graph view
## (the tutorial IS the graph interface), top-center under the toolbar.

signal briefing_requested
signal exit_requested

var _panel: PanelContainer = null
var _title_lbl: Label = null
var _objective_lbl: Label = null
var _progress_lbl: Label = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	offset_top = 64.0
	offset_bottom = 64.0
	visible = false
	_build_ui()


func show_level(index: int, title: String, objective: String) -> void:
	_title_lbl.text = "🎓  Level %d — %s" % [index, title]
	_objective_lbl.text = objective
	_progress_lbl.text = ""
	visible = true


func set_progress(text: String) -> void:
	_progress_lbl.text = text
	_progress_lbl.visible = not text.is_empty()


func hide_hud() -> void:
	visible = false


func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.add_theme_stylebox_override("panel", UITheme.panel_style(0.92))
	_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	add_child(_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", UITheme.SPACE_MD)
	margin.add_theme_constant_override("margin_right", UITheme.SPACE_MD)
	margin.add_theme_constant_override("margin_top", UITheme.SPACE_XS)
	margin.add_theme_constant_override("margin_bottom", UITheme.SPACE_XS)
	_panel.add_child(margin)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITheme.SPACE_MD)
	margin.add_child(row)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	row.add_child(col)

	_title_lbl = Label.new()
	_title_lbl.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	_title_lbl.add_theme_font_size_override("font_size", UITheme.FONT_MD)
	col.add_child(_title_lbl)

	_objective_lbl = Label.new()
	_objective_lbl.add_theme_color_override("font_color", UITheme.C_TEXT)
	_objective_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	col.add_child(_objective_lbl)

	_progress_lbl = Label.new()
	_progress_lbl.add_theme_color_override("font_color", UITheme.C_AMBER)
	_progress_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	col.add_child(_progress_lbl)

	var brief_btn := Button.new()
	brief_btn.text = "Briefing"
	brief_btn.tooltip_text = "Re-read this level's briefing"
	UITheme.style_button(brief_btn)
	brief_btn.pressed.connect(func() -> void: briefing_requested.emit())
	row.add_child(brief_btn)

	var exit_btn := Button.new()
	exit_btn.text = "Exit"
	exit_btn.tooltip_text = "Leave the bootcamp — your real graph comes back untouched"
	UITheme.style_button(exit_btn)
	exit_btn.pressed.connect(func() -> void: exit_requested.emit())
	row.add_child(exit_btn)
