class_name TutorialHud
extends Control

## Compact objective strip for the Solar Bootcamp — parented to the graph view
## (the tutorial IS the graph interface), top-center under the toolbar.

signal briefing_requested
signal exit_requested
signal run_requested
## Playback speed multiplier picked during a run (1 / 2 / 4).
signal run_speed_requested(mult: float)
## Skip the rest of the sweep and show the result now.
signal run_skip_requested

const SPEED_STEPS: Array[float] = [1.0, 2.0, 4.0]

var _panel: PanelContainer = null
var _title_lbl: Label = null
var _objective_lbl: Label = null
var _progress_lbl: Label = null
var _run_btn: Button = null
var _speed_btn: Button = null
var _skip_btn: Button = null
var _speed_idx: int = 0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	offset_top = 64.0
	offset_bottom = 64.0
	visible = false
	_build_ui()


func show_level(index: int, title: String, objective: String,
		is_run_level: bool = false) -> void:
	_title_lbl.text = "🎓  Level %d — %s" % [index, title]
	_objective_lbl.text = objective
	_progress_lbl.text = ""
	_run_btn.visible = is_run_level
	_run_btn.disabled = false
	visible = true


## A run is under way: swap the Run button for the speed + skip controls, which
## are only meaningful while the sweep is playing.
func set_run_busy(busy: bool) -> void:
	if _run_btn != null:
		_run_btn.disabled = busy
	if _speed_btn != null:
		_speed_btn.visible = busy
	if _skip_btn != null:
		_skip_btn.visible = busy
	if busy:
		_speed_idx = 0
		_refresh_speed_label()


func set_progress(text: String) -> void:
	_progress_lbl.text = text
	_progress_lbl.visible = not text.is_empty()
	# "Something is destroyed" (TutorialGoals._evaluate_build's any_destroyed
	# gate) blocks EVERY build goal until RESET is pressed, with no other
	# indicator once the fault card is dismissed — a player who blew something
	# up testing a level's "or don't, and see what happens" path, then rewired
	# without resetting, sees no failure and no success. Give that specific
	# case the same red as an active fault instead of blending into ordinary
	# amber progress text.
	_progress_lbl.add_theme_color_override("font_color",
		UITheme.C_ERROR if "destroyed" in text.to_lower() else UITheme.C_AMBER)


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

	_run_btn = Button.new()
	_run_btn.text = "▶ Run 24 h"
	_run_btn.tooltip_text = "Pre-compute a full day and play it back"
	UITheme.style_button(_run_btn)
	_run_btn.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	_run_btn.visible = false
	_run_btn.pressed.connect(func() -> void: run_requested.emit())
	row.add_child(_run_btn)

	_speed_btn = Button.new()
	_speed_btn.tooltip_text = "Playback speed"
	UITheme.style_button(_speed_btn)
	_speed_btn.visible = false
	_speed_btn.pressed.connect(_on_speed_pressed)
	row.add_child(_speed_btn)
	_refresh_speed_label()

	_skip_btn = Button.new()
	_skip_btn.text = "Skip ⏭"
	_skip_btn.tooltip_text = "Finish the run and show the result now"
	UITheme.style_button(_skip_btn)
	_skip_btn.visible = false
	_skip_btn.pressed.connect(func() -> void: run_skip_requested.emit())
	row.add_child(_skip_btn)

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


func _on_speed_pressed() -> void:
	_speed_idx = (_speed_idx + 1) % SPEED_STEPS.size()
	_refresh_speed_label()
	run_speed_requested.emit(SPEED_STEPS[_speed_idx])


func _refresh_speed_label() -> void:
	if _speed_btn != null:
		_speed_btn.text = "%.0f×" % SPEED_STEPS[_speed_idx]
