class_name ToastUI
extends CanvasLayer

## Global HUD toast stack. Surfaces failures/confirmations that were
## previously console-only (push_warning), so the player actually sees them.
##
## Wiring split to avoid duplicate toasts for the same event:
## - WeatherService's weather_fetch_failed/forecast_fetch_failed have no other
##   subscriber, so ToastUI connects to them directly here in _ready().
## - ElevationService/ImageryService's elevation_failed/imagery_failed are
##   already exclusively owned by terrain_loader.gd (it connects/disconnects
##   them per load and already picks curated fallback messages), so ToastUI
##   does NOT also subscribe to those raw signals — terrain_loader calls
##   show_toast() directly at its fallback branches instead.
##
## Usage: get the instance from Main (main.gd creates it under UILayer) and
## call show_toast(text, level, duration), or use Main.show_toast(...).

enum Level { INFO, OK, WARN, ERROR }

const MAX_TOASTS := 4
const DEFAULT_DURATION := 5.0
const FADE_S := 0.35
const TOAST_WIDTH := 360.0
const STACK_HEIGHT := 400.0

var _stack: VBoxContainer = null
var _entries: Array[PanelContainer] = []


func _ready() -> void:
	layer = UITheme.LAYER_TOAST
	_build_stack()
	_connect_service_signals()


## level: one of ToastUI.Level. duration: seconds before auto-dismiss.
func show_toast(text: String, level: Level = Level.INFO, duration: float = DEFAULT_DURATION) -> void:
	if _stack == null:
		return
	if _entries.size() >= MAX_TOASTS:
		_remove_entry(_entries[0])
	var entry := _make_entry(text, level)
	_stack.add_child(entry)
	_entries.append(entry)
	var timer := get_tree().create_timer(duration)
	timer.timeout.connect(_fade_and_remove.bind(entry), CONNECT_ONE_SHOT)


func _build_stack() -> void:
	_stack = VBoxContainer.new()
	_stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stack.add_theme_constant_override("separation", UITheme.SPACE_SM)
	_stack.alignment = BoxContainer.ALIGNMENT_END
	_stack.anchor_left = 1.0
	_stack.anchor_right = 1.0
	_stack.anchor_top = 1.0
	_stack.anchor_bottom = 1.0
	_stack.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_stack.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_stack.offset_right = -UiScreenLayout.SIDE_MARGIN
	_stack.offset_bottom = -UiScreenLayout.timeline_stack_height()
	_stack.offset_left = _stack.offset_right - TOAST_WIDTH
	_stack.offset_top = _stack.offset_bottom - STACK_HEIGHT
	_stack.custom_minimum_size = Vector2(TOAST_WIDTH, 0.0)
	add_child(_stack)


func _make_entry(text: String, level: Level) -> PanelContainer:
	var color := _level_color(level)
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.modulate = Color(1.0, 1.0, 1.0, 1.0)
	panel.add_theme_stylebox_override("panel", UITheme.chip_style(color))
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", UITheme.SPACE_MD)
	margin.add_theme_constant_override("margin_right", UITheme.SPACE_MD)
	margin.add_theme_constant_override("margin_top", UITheme.SPACE_SM)
	margin.add_theme_constant_override("margin_bottom", UITheme.SPACE_SM)
	panel.add_child(margin)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITheme.SPACE_SM)
	margin.add_child(row)
	var dot := Label.new()
	dot.text = _level_icon(level)
	dot.add_theme_color_override("font_color", color)
	row.add_child(dot)
	var lbl := Label.new()
	lbl.text = text
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.custom_minimum_size = Vector2(TOAST_WIDTH - 64.0, 0.0)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	lbl.add_theme_color_override("font_color", UITheme.C_TEXT)
	row.add_child(lbl)
	return panel


func _level_color(level: Level) -> Color:
	match level:
		Level.OK:
			return UITheme.C_OK
		Level.WARN:
			return UITheme.C_WARN
		Level.ERROR:
			return UITheme.C_ERROR
		_:
			return UITheme.C_INFO


func _level_icon(level: Level) -> String:
	match level:
		Level.OK:
			return "✓"
		Level.WARN:
			return "⚠"
		Level.ERROR:
			return "✕"
		_:
			return "ℹ"


func _fade_and_remove(entry: PanelContainer) -> void:
	if not is_instance_valid(entry):
		return
	var tw := create_tween()
	tw.tween_property(entry, "modulate:a", 0.0, FADE_S)
	tw.tween_callback(_remove_entry.bind(entry))


func _remove_entry(entry: PanelContainer) -> void:
	if not is_instance_valid(entry):
		return
	_entries.erase(entry)
	entry.queue_free()


func _connect_service_signals() -> void:
	var weather := get_node_or_null("/root/WeatherService")
	if weather != null:
		if weather.has_signal("weather_fetch_failed") \
				and not weather.weather_fetch_failed.is_connected(_on_weather_fetch_failed):
			weather.weather_fetch_failed.connect(_on_weather_fetch_failed)
		if weather.has_signal("forecast_fetch_failed") \
				and not weather.forecast_fetch_failed.is_connected(_on_forecast_fetch_failed):
			weather.forecast_fetch_failed.connect(_on_forecast_fetch_failed)


func _on_weather_fetch_failed(reason: String) -> void:
	show_toast("Weather data unavailable — %s" % reason, Level.WARN)


func _on_forecast_fetch_failed(reason: String) -> void:
	show_toast("Forecast unavailable — %s" % reason, Level.WARN)
