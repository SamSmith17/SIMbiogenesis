class_name TerrainLoadOverlay
extends CanvasLayer

## Full-screen blocker during the walkability gate, then a compact bottom bar until
## background layers finish. Shows "Map loaded" briefly before dismissing.

signal dismissed

const C_BG := Color(0.04, 0.05, 0.10, 0.72)
const C_TEXT := Color(0.88, 0.91, 0.94, 1.0)
const C_MUTED := Color(0.58, 0.64, 0.72, 1.0)
const C_ACCENT := Color(0.13, 0.82, 0.93, 1.0)
const C_OK := Color(0.15, 0.90, 0.47, 1.0)
const TIMELINE_CLEARANCE := 162.0  # TimelineUI bar + margin

const COMPLETE_HOLD_S := 2.2
const COMPLETE_HOLD_FAST_S := 0.75

var _dim: ColorRect = null
var _center: CenterContainer = null
var _card: PanelContainer = null
var _title_lbl: Label = null
var _stage_lbl: Label = null
var _hint_lbl: Label = null
var _bar: ProgressBar = null
var _pct_lbl: Label = null
var _compact_bar: PanelContainer = null
var _compact_stage: Label = null
var _compact_bar_widget: ProgressBar = null
var _compact_pct: Label = null
var _compact := false
var _complete := false
var _dismiss_timer: SceneTreeTimer = null


func setup(title: String) -> void:
	layer = 100
	_build_full(title)
	_build_compact()
	_set_compact_visible(false)


func set_title(title: String) -> void:
	if _title_lbl != null:
		_title_lbl.text = title


func set_progress(ratio: float, stage_label: String, hint: String = "") -> void:
	var pct := int(round(ratio * 100.0))
	if _bar != null:
		_bar.value = ratio * 100.0
	if _pct_lbl != null:
		_pct_lbl.text = "%d%%" % pct
	if _stage_lbl != null:
		_stage_lbl.text = stage_label
	if _hint_lbl != null:
		_hint_lbl.text = hint
	if _compact_bar_widget != null:
		_compact_bar_widget.value = ratio * 100.0
	if _compact_pct != null:
		_compact_pct.text = "%d%%" % pct
	if _compact_stage != null:
		_compact_stage.text = stage_label if hint.is_empty() else "%s — %s" % [stage_label, hint]


func enter_compact_mode() -> void:
	if _compact:
		return
	_compact = true
	if _dim != null:
		_dim.color = Color(0.0, 0.0, 0.0, 0.0)
		_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _center != null:
		_center.visible = false
	_set_compact_visible(true)


func show_map_loaded(fast_dismiss: bool = false) -> void:
	_complete = true
	set_progress(1.0, "Map loaded", "")
	if _title_lbl != null:
		_title_lbl.text = "Map loaded"
	if _stage_lbl != null:
		_stage_lbl.text = "Ready to explore"
	if _bar != null:
		_bar.modulate = C_OK
	if _compact_bar_widget != null:
		_compact_bar_widget.modulate = C_OK
	if _compact_stage != null:
		_compact_stage.text = "Map loaded"
	if _compact_pct != null:
		_compact_pct.text = "100%"
	if _dismiss_timer != null and _dismiss_timer.time_left > 0.0:
		return
	var hold := COMPLETE_HOLD_FAST_S if fast_dismiss else COMPLETE_HOLD_S
	_dismiss_timer = get_tree().create_timer(hold)
	_dismiss_timer.timeout.connect(_on_dismiss_timeout, CONNECT_ONE_SHOT)


func dismiss_now() -> void:
	if _dismiss_timer != null:
		if _dismiss_timer.timeout.is_connected(_on_dismiss_timeout):
			_dismiss_timer.timeout.disconnect(_on_dismiss_timeout)
		_dismiss_timer = null
	queue_free()
	dismissed.emit()


func _on_dismiss_timeout() -> void:
	dismiss_now()


func _build_full(title: String) -> void:
	_dim = ColorRect.new()
	_dim.color = C_BG
	_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_dim)

	_center = CenterContainer.new()
	_center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_center)

	_card = PanelContainer.new()
	_card.custom_minimum_size = Vector2(420, 0)
	_center.add_child(_card)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", 18)
	margin.add_theme_constant_override("margin_bottom", 18)
	_card.add_child(margin)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	margin.add_child(col)

	_title_lbl = Label.new()
	_title_lbl.text = title
	_title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_lbl.add_theme_font_size_override("font_size", 20)
	_title_lbl.add_theme_color_override("font_color", C_TEXT)
	col.add_child(_title_lbl)

	_stage_lbl = Label.new()
	_stage_lbl.text = "Starting …"
	_stage_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_stage_lbl.add_theme_font_size_override("font_size", 15)
	_stage_lbl.add_theme_color_override("font_color", C_MUTED)
	col.add_child(_stage_lbl)

	_bar = ProgressBar.new()
	_bar.custom_minimum_size = Vector2(360, 22)
	_bar.max_value = 100.0
	_bar.show_percentage = false
	_style_bar(_bar)
	col.add_child(_bar)

	var row := HBoxContainer.new()
	col.add_child(row)
	_hint_lbl = Label.new()
	_hint_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hint_lbl.add_theme_font_size_override("font_size", 12)
	_hint_lbl.add_theme_color_override("font_color", C_MUTED)
	row.add_child(_hint_lbl)
	_pct_lbl = Label.new()
	_pct_lbl.text = "0%"
	_pct_lbl.add_theme_font_size_override("font_size", 12)
	_pct_lbl.add_theme_color_override("font_color", C_ACCENT)
	row.add_child(_pct_lbl)


func _build_compact() -> void:
	_compact_bar = PanelContainer.new()
	_compact_bar.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_compact_bar.offset_left = 80.0
	_compact_bar.offset_right = -80.0
	_compact_bar.offset_bottom = -TIMELINE_CLEARANCE
	_compact_bar.offset_top = -(TIMELINE_CLEARANCE + 44.0)
	_compact_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_compact_bar)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	_compact_bar.add_child(margin)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	margin.add_child(col)
	var row := HBoxContainer.new()
	col.add_child(row)
	_compact_stage = Label.new()
	_compact_stage.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_compact_stage.text = "Loading …"
	_compact_stage.add_theme_font_size_override("font_size", 13)
	_compact_stage.add_theme_color_override("font_color", C_TEXT)
	row.add_child(_compact_stage)
	_compact_pct = Label.new()
	_compact_pct.text = "0%"
	_compact_pct.add_theme_font_size_override("font_size", 13)
	_compact_pct.add_theme_color_override("font_color", C_ACCENT)
	row.add_child(_compact_pct)
	_compact_bar_widget = ProgressBar.new()
	_compact_bar_widget.custom_minimum_size = Vector2(0, 14)
	_compact_bar_widget.max_value = 100.0
	_compact_bar_widget.show_percentage = false
	_style_bar(_compact_bar_widget)
	col.add_child(_compact_bar_widget)


func _style_bar(bar: ProgressBar) -> void:
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.12, 0.14, 0.20, 1.0)
	bg.corner_radius_top_left = 4
	bg.corner_radius_top_right = 4
	bg.corner_radius_bottom_left = 4
	bg.corner_radius_bottom_right = 4
	var fill := StyleBoxFlat.new()
	fill.bg_color = C_ACCENT
	fill.corner_radius_top_left = 4
	fill.corner_radius_top_right = 4
	fill.corner_radius_bottom_left = 4
	fill.corner_radius_bottom_right = 4
	bar.add_theme_stylebox_override("background", bg)
	bar.add_theme_stylebox_override("fill", fill)


func _set_compact_visible(on: bool) -> void:
	if _compact_bar != null:
		_compact_bar.visible = on
