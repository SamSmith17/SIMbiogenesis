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
## Part-complete celebrations: show_part_up(label, count) / Main.show_part_up(...).
## Stack is centered just above the timeline so it never covers the right sidebar.

enum Level { INFO, OK, WARN, ERROR }

const _UI_SFX := preload("res://core/ui_sfx.gd")
const MAX_TOASTS := 3
const DEFAULT_DURATION := 3.0
const PART_UP_DURATION := 2.2
const FADE_S := 0.2
const POP_S := 0.14
const TOAST_WIDTH := 220.0
const STACK_HEIGHT := 160.0
const ABOVE_TIMELINE_GAP := 10.0

var _stack: VBoxContainer = null
var _entries: Array[PanelContainer] = []


func _ready() -> void:
	layer = UITheme.LAYER_TOAST
	_build_stack()
	_connect_service_signals()
	_bind_timeline_clearance()


## level: one of ToastUI.Level. duration: seconds before auto-dismiss.
func show_toast(text: String, level: Level = Level.INFO, duration: float = DEFAULT_DURATION) -> void:
	if _stack == null:
		return
	_play_level_sfx(level)
	if _entries.size() >= MAX_TOASTS:
		_remove_entry(_entries[0])
	var entry := _make_entry(text, level)
	_stack.add_child(entry)
	_entries.append(entry)
	var timer := get_tree().create_timer(duration)
	timer.timeout.connect(_fade_and_remove.bind(entry), CONNECT_ONE_SHOT)


## One hook covers every toast in the game: the severity the caller already
## passes picks the feedback tier. INFO stays silent — most toasts are status
## chatter, and a sound on all of them would train the player to ignore it.
## `danger` is skipped when a destroy FX is already booming (it plays its own).
func _play_level_sfx(level: Level, allow_danger: bool = true) -> void:
	var sfx := get_node_or_null("/root/UiSound")
	if sfx == null:
		return
	match level:
		Level.OK:
			sfx.call("play_ui", _UI_SFX.SUCCESS, 120)
		Level.WARN:
			sfx.call("play_ui", _UI_SFX.WARN, 250)
		Level.ERROR:
			if allow_danger:
				sfx.call("play_ui", _UI_SFX.DANGER, 250)


## Community status chip: an icon, a short headline, and an optional dim
## detail line — "👋  Devi left / no water". Built for the settlement's story
## beats (departures, collapse, qualifications), which used to render as one
## long sentence in the graph view's private single-slot label and were
## therefore invisible everywhere else. Same stack, same cap, same fades as
## every other toast, so a burst of departures queues instead of overwriting.
func show_community(kind: String, title: String, detail: String = "",
		level: Level = Level.INFO, duration: float = 4.0) -> void:
	if _stack == null:
		return
	_play_level_sfx(level)
	if _entries.size() >= MAX_TOASTS:
		_remove_entry(_entries[0])
	var entry := _make_community_entry(kind, title, detail, level)
	_stack.add_child(entry)
	_entries.append(entry)
	_pop_in(entry)
	var timer := get_tree().create_timer(duration)
	timer.timeout.connect(_fade_and_remove.bind(entry), CONNECT_ONE_SHOT)


func _make_community_entry(kind: String, title: String, detail: String,
		level: Level) -> PanelContainer:
	var color := _level_color(level)
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.modulate = Color(1.0, 1.0, 1.0, 0.0)
	panel.pivot_offset = Vector2(TOAST_WIDTH * 0.5, 18.0)
	panel.scale = Vector2(0.94, 0.94)
	panel.add_theme_stylebox_override("panel", UITheme.chip_style(color))
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", UITheme.SPACE_SM)
	margin.add_theme_constant_override("margin_right", UITheme.SPACE_SM)
	margin.add_theme_constant_override("margin_top", 4)
	margin.add_theme_constant_override("margin_bottom", 4)
	panel.add_child(margin)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	margin.add_child(row)
	var icon := Label.new()
	icon.text = SettlementLog.icon_for(kind)
	icon.add_theme_font_size_override("font_size", UITheme.FONT_MD)
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(icon)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(col)
	var head := Label.new()
	head.text = title
	head.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	head.custom_minimum_size = Vector2(TOAST_WIDTH - 52.0, 0.0)
	head.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	head.add_theme_color_override("font_color", UITheme.C_TEXT)
	col.add_child(head)
	if not detail.is_empty():
		var sub := Label.new()
		sub.text = detail
		sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		sub.custom_minimum_size = Vector2(TOAST_WIDTH - 52.0, 0.0)
		sub.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		# NOT C_TEXT_S: the chip background is TINTED, and the muted grey
		# disappears into it — the detail is the "why", which must survive.
		sub.add_theme_color_override("font_color", Color(UITheme.C_TEXT, 0.78))
		col.add_child(sub)
	return panel


## Compact +N UP chip when a fabricated part lands in inventory.
func show_part_up(label: String, count: int = 1, duration: float = PART_UP_DURATION) -> void:
	if _stack == null:
		return
	if _entries.size() >= MAX_TOASTS:
		_remove_entry(_entries[0])
	var n := maxi(count, 1)
	var entry := _make_part_up_entry(label, n)
	_stack.add_child(entry)
	_entries.append(entry)
	_pop_in(entry)
	var timer := get_tree().create_timer(duration)
	timer.timeout.connect(_fade_and_remove.bind(entry), CONNECT_ONE_SHOT)


func _build_stack() -> void:
	_stack = VBoxContainer.new()
	_stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stack.add_theme_constant_override("separation", 4)
	_stack.alignment = BoxContainer.ALIGNMENT_END
	# Centered horizontally, pinned just above the timeline.
	_stack.anchor_left = 0.5
	_stack.anchor_right = 0.5
	_stack.anchor_top = 1.0
	_stack.anchor_bottom = 1.0
	_stack.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_stack.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_stack.custom_minimum_size = Vector2(TOAST_WIDTH, 0.0)
	_apply_stack_clearance(UiScreenLayout.timeline_stack_height())
	add_child(_stack)


func _bind_timeline_clearance() -> void:
	call_deferred("_refresh_timeline_clearance")
	var tree := get_tree()
	if tree == null:
		return
	var tl := tree.root.find_child("TimelineUI", true, false)
	if tl != null and tl.has_signal("stack_height_changed") \
			and not tl.stack_height_changed.is_connected(_on_timeline_stack_height):
		tl.stack_height_changed.connect(_on_timeline_stack_height)


func _on_timeline_stack_height(h: float) -> void:
	_apply_stack_clearance(h)


func _refresh_timeline_clearance() -> void:
	var tree := get_tree()
	if tree == null:
		return
	var tl := tree.root.find_child("TimelineUI", true, false)
	if tl != null and tl.has_method("get_stack_height"):
		_apply_stack_clearance(float(tl.call("get_stack_height")))
		if tl.has_signal("stack_height_changed") \
				and not tl.stack_height_changed.is_connected(_on_timeline_stack_height):
			tl.stack_height_changed.connect(_on_timeline_stack_height)
	else:
		_apply_stack_clearance(UiScreenLayout.timeline_stack_height())


func _apply_stack_clearance(timeline_h: float) -> void:
	if _stack == null:
		return
	var clearance := maxf(timeline_h, UiScreenLayout.timeline_stack_height()) + ABOVE_TIMELINE_GAP
	_stack.offset_bottom = -clearance
	_stack.offset_top = _stack.offset_bottom - STACK_HEIGHT
	_stack.offset_left = -TOAST_WIDTH * 0.5
	_stack.offset_right = TOAST_WIDTH * 0.5


func _make_entry(text: String, level: Level) -> PanelContainer:
	var color := _level_color(level)
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.modulate = Color(1.0, 1.0, 1.0, 1.0)
	panel.add_theme_stylebox_override("panel", UITheme.chip_style(color))
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", UITheme.SPACE_SM)
	margin.add_theme_constant_override("margin_right", UITheme.SPACE_SM)
	margin.add_theme_constant_override("margin_top", 4)
	margin.add_theme_constant_override("margin_bottom", 4)
	panel.add_child(margin)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	margin.add_child(row)
	var dot := Label.new()
	dot.text = _level_icon(level)
	dot.add_theme_color_override("font_color", color)
	dot.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	row.add_child(dot)
	var lbl := Label.new()
	lbl.text = text
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.custom_minimum_size = Vector2(TOAST_WIDTH - 40.0, 0.0)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	lbl.add_theme_color_override("font_color", UITheme.C_TEXT)
	row.add_child(lbl)
	return panel


func _make_part_up_entry(label: String, count: int) -> PanelContainer:
	var color := UITheme.C_OK
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.modulate = Color(1.0, 1.0, 1.0, 0.0)
	panel.pivot_offset = Vector2(TOAST_WIDTH * 0.5, 18.0)
	panel.scale = Vector2(0.94, 0.94)
	var style := UITheme.chip_style(color)
	style.set_content_margin_all(4)
	style.content_margin_left = UITheme.SPACE_SM
	style.content_margin_right = UITheme.SPACE_SM
	panel.add_theme_stylebox_override("panel", style)

	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 6)
	panel.add_child(row)

	var title := Label.new()
	title.text = "+%d UP" % count
	title.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	title.add_theme_color_override("font_color", color)
	row.add_child(title)

	var body := Label.new()
	var part := label.strip_edges()
	if part.is_empty():
		part = "part"
	body.text = part
	body.clip_text = true
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.custom_minimum_size = Vector2(72.0, 0.0)
	body.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	body.add_theme_color_override("font_color", UITheme.C_TEXT)
	row.add_child(body)

	var btn := Button.new()
	btn.text = "Bag"
	btn.focus_mode = Control.FOCUS_NONE
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	btn.add_theme_color_override("font_color", color)
	btn.add_theme_stylebox_override("normal", _part_up_btn_style(Color(color, 0.12)))
	btn.add_theme_stylebox_override("hover", _part_up_btn_style(Color(color, 0.22)))
	btn.add_theme_stylebox_override("pressed", _part_up_btn_style(Color(color, 0.30)))
	btn.pressed.connect(_on_part_up_inventory_pressed.bind(panel))
	row.add_child(btn)
	return panel


func _part_up_btn_style(bg: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(3)
	sb.set_content_margin_all(2)
	sb.content_margin_left = 6
	sb.content_margin_right = 6
	return sb


func _pop_in(entry: PanelContainer) -> void:
	if not is_instance_valid(entry):
		return
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(entry, "modulate:a", 1.0, POP_S).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(entry, "scale", Vector2.ONE, POP_S).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _on_part_up_inventory_pressed(entry: PanelContainer) -> void:
	var sgv := get_tree().root.find_child("SystemGraphView", true, false)
	if sgv != null and sgv.has_method("open_inventory_panel"):
		sgv.call("open_inventory_panel")
	_fade_and_remove(entry)


## Hybrid chore gate: recipe paused until Confirm. Calls on_confirm then dismisses.
func show_chore_confirm(item_id: String, label: String, chore_hours: float = 0.0,
		on_confirm: Callable = Callable(), duration: float = 12.0) -> void:
	if _stack == null:
		return
	if _entries.size() >= MAX_TOASTS:
		_remove_entry(_entries[0])
	var entry := _make_chore_confirm_entry(item_id, label, chore_hours, on_confirm)
	_stack.add_child(entry)
	_entries.append(entry)
	_pop_in(entry)
	var timer := get_tree().create_timer(duration)
	timer.timeout.connect(_fade_and_remove.bind(entry), CONNECT_ONE_SHOT)


func _make_chore_confirm_entry(item_id: String, label: String, chore_hours: float,
		on_confirm: Callable) -> PanelContainer:
	var color := UITheme.C_INFO
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.modulate = Color(1.0, 1.0, 1.0, 0.0)
	panel.pivot_offset = Vector2(TOAST_WIDTH * 0.5, 24.0)
	panel.scale = Vector2(0.94, 0.94)
	var style := UITheme.chip_style(color)
	style.set_content_margin_all(UITheme.SPACE_SM)
	panel.add_theme_stylebox_override("panel", style)

	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_theme_constant_override("separation", 2)
	panel.add_child(col)

	var title := Label.new()
	title.text = "Chore"
	title.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	title.add_theme_color_override("font_color", color)
	col.add_child(title)

	var body := Label.new()
	var hrs := ""
	if chore_hours > 0.001:
		hrs = " (%.2f h)" % chore_hours
	body.text = "%s%s" % [label, hrs]
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.custom_minimum_size = Vector2(TOAST_WIDTH - 24.0, 0.0)
	body.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	body.add_theme_color_override("font_color", UITheme.C_TEXT)
	col.add_child(body)

	var btn := Button.new()
	btn.text = "Confirm"
	btn.focus_mode = Control.FOCUS_NONE
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	btn.add_theme_color_override("font_color", color)
	btn.add_theme_stylebox_override("normal", _part_up_btn_style(Color(color, 0.12)))
	btn.add_theme_stylebox_override("hover", _part_up_btn_style(Color(color, 0.22)))
	btn.add_theme_stylebox_override("pressed", _part_up_btn_style(Color(color, 0.30)))
	btn.pressed.connect(func():
		if on_confirm.is_valid():
			on_confirm.call()
		else:
			var sgv := get_tree().root.find_child("SystemGraphView", true, false)
			if sgv != null and sgv.has_method("confirm_recipe_chore"):
				sgv.call("confirm_recipe_chore", item_id)
		_fade_and_remove(panel)
	)
	col.add_child(btn)
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
