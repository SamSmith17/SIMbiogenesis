extends Control

## Routines & chores for one pop-driven habitat: who is here, how they feel,
## what work is queued, and — the key affordance — a per-person day-plan strip
## showing sleep / needs / chores / free time, so over-scheduling is VISIBLE
## instead of being discovered through a collapse.
##
## Instantiated lazily by SystemGraphView (record_book / site_report pattern),
## styled through UITheme, signals wired in _ready.

const MODAL_NAME := "npc_routines"

const C_BG := UITheme.C_BG
const C_PANEL := UITheme.C_PANEL
const C_TEXT := UITheme.C_TEXT
const C_TEXT_DIM := UITheme.C_TEXT_S

## Day-plan strip colours.
const C_SLEEP := Color(0.42, 0.40, 0.72)
const C_NEEDS := Color(0.30, 0.62, 0.80)
const C_CHORE := Color(0.86, 0.62, 0.28)
const C_FREE := Color(0.32, 0.66, 0.42)
const C_OVER := Color(0.88, 0.28, 0.30)

var _bridge = null                 # NpcPopulationBridge
var _item_id := ""
var _active := false

var _dim: ColorRect = null
var _panel: PanelContainer = null
var _title: Label = null
var _weather_lbl: Label = null
var _walk_lbl: Label = null
var _roster_box: VBoxContainer = null
var _chore_box: VBoxContainer = null
var _new_label: LineEdit = null
var _new_hours: SpinBox = null
var _new_start: SpinBox = null
var _new_end: SpinBox = null
var _new_exposure: OptionButton = null
var _new_assign: OptionButton = null
var _refresh_accum := 0.0


func _ready() -> void:
	visible = false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)
	_build_ui()


func bind(bridge, item_id: String) -> void:
	_bridge = bridge
	_item_id = item_id


func open(bridge, item_id: String) -> void:
	bind(bridge, item_id)
	_active = true
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(true)
	move_to_front()
	_refresh_assign_options()
	_refresh()
	CursorController.request_modal(MODAL_NAME, Callable(self, "close"))


func close() -> void:
	if not _active:
		return
	_active = false
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)
	CursorController.release_modal(MODAL_NAME)


func _unhandled_input(event: InputEvent) -> void:
	if not _active:
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		close()
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	# The sim keeps running behind the panel; refresh at a readable cadence.
	_refresh_accum += delta
	if _refresh_accum >= 0.5:
		_refresh_accum = 0.0
		_refresh()


# --- construction -----------------------------------------------------------

func _build_ui() -> void:
	_dim = ColorRect.new()
	_dim.color = Color(0, 0, 0, 0.55)
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_dim)

	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", UITheme.panel_style())
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.anchor_left = 0.5
	_panel.anchor_right = 0.5
	_panel.anchor_top = 0.5
	_panel.anchor_bottom = 0.5
	_panel.offset_left = -520
	_panel.offset_right = 520
	_panel.offset_top = -330
	_panel.offset_bottom = 330
	add_child(_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 12)
	_panel.add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	margin.add_child(root)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	root.add_child(header)
	_title = Label.new()
	_title.text = "Routines & Chores"
	_title.add_theme_font_size_override("font_size", 18)
	_title.add_theme_color_override("font_color", C_TEXT)
	header.add_child(_title)
	_weather_lbl = Label.new()
	_weather_lbl.add_theme_font_size_override("font_size", 12)
	_weather_lbl.add_theme_color_override("font_color", C_TEXT_DIM)
	_weather_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_weather_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(_weather_lbl)
	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.pressed.connect(close)
	header.add_child(close_btn)

	_walk_lbl = Label.new()
	_walk_lbl.add_theme_font_size_override("font_size", 12)
	_walk_lbl.add_theme_color_override("font_color", C_TEXT_DIM)
	root.add_child(_walk_lbl)

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.split_offset = 560
	root.add_child(split)

	# Left: roster with day-plan strips.
	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 4)
	split.add_child(left)
	left.add_child(_section_label("People"))
	var legend := HBoxContainer.new()
	legend.add_theme_constant_override("separation", 10)
	left.add_child(legend)
	for pair in [["Sleep", C_SLEEP], ["Needs", C_NEEDS], ["Chores", C_CHORE], ["Free", C_FREE]]:
		legend.add_child(_legend_chip(str((pair as Array)[0]), (pair as Array)[1] as Color))
	var roster_scroll := ScrollContainer.new()
	roster_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(roster_scroll)
	_roster_box = VBoxContainer.new()
	_roster_box.add_theme_constant_override("separation", 3)
	_roster_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	roster_scroll.add_child(_roster_box)

	# Right: the chore board + authoring row.
	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 4)
	split.add_child(right)
	right.add_child(_section_label("Chore board"))
	var chore_scroll := ScrollContainer.new()
	chore_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(chore_scroll)
	_chore_box = VBoxContainer.new()
	_chore_box.add_theme_constant_override("separation", 3)
	_chore_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chore_scroll.add_child(_chore_box)
	right.add_child(HSeparator.new())
	right.add_child(_build_new_chore_row())


func _section_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 14)
	l.add_theme_color_override("font_color", C_TEXT)
	return l


func _legend_chip(text: String, col: Color) -> HBoxContainer:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	var swatch := ColorRect.new()
	swatch.color = col
	swatch.custom_minimum_size = Vector2(10, 10)
	swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	box.add_child(swatch)
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 10)
	l.add_theme_color_override("font_color", C_TEXT_DIM)
	box.add_child(l)
	return box


func _build_new_chore_row() -> VBoxContainer:
	var wrap := VBoxContainer.new()
	wrap.add_theme_constant_override("separation", 3)
	wrap.add_child(_section_label("Add a chore"))

	var row1 := HBoxContainer.new()
	row1.add_theme_constant_override("separation", 6)
	wrap.add_child(row1)
	_new_label = LineEdit.new()
	_new_label.placeholder_text = "What needs doing"
	_new_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row1.add_child(_new_label)
	_new_hours = _spin(0.25, 0.25, 12.0, 1.0)
	row1.add_child(_labelled("Hours", _new_hours))

	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 6)
	wrap.add_child(row2)
	_new_start = _spin(1.0, 0.0, 23.0, 8.0)
	row2.add_child(_labelled("From", _new_start))
	_new_end = _spin(1.0, 1.0, 24.0, 18.0)
	row2.add_child(_labelled("To", _new_end))
	_new_exposure = OptionButton.new()
	for e in NpcWeatherGate.EXPOSURES:
		_new_exposure.add_item(str(e).capitalize())
	_new_exposure.select(NpcWeatherGate.EXPOSURES.find(NpcWeatherGate.EXPOSURE_OUTDOOR))
	row2.add_child(_labelled("Exposure", _new_exposure))
	_new_assign = OptionButton.new()
	_new_assign.custom_minimum_size.x = 130
	row2.add_child(_labelled("Who", _new_assign))
	var add_btn := Button.new()
	add_btn.text = "Add"
	add_btn.pressed.connect(_on_add_chore)
	row2.add_child(add_btn)
	return wrap


func _spin(step: float, min_v: float, max_v: float, value: float) -> SpinBox:
	var s := SpinBox.new()
	s.step = step
	s.min_value = min_v
	s.max_value = max_v
	s.value = value
	s.custom_minimum_size.x = 72
	return s


func _labelled(text: String, control: Control) -> VBoxContainer:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 10)
	l.add_theme_color_override("font_color", C_TEXT_DIM)
	col.add_child(l)
	col.add_child(control)
	return col


# --- refresh ----------------------------------------------------------------

func _board() -> NpcChoreBoard:
	if _bridge == null or _item_id.is_empty():
		return null
	return _bridge.chore_board_for(_item_id)


func _refresh_assign_options() -> void:
	if _new_assign == null or _bridge == null:
		return
	var prev := str(_new_assign.get_selected_metadata())
	_new_assign.clear()
	_new_assign.add_item("Anyone free")
	_new_assign.set_item_metadata(0, "")
	for a in _bridge.roster_for(_item_id):
		var agent: NpcAgent = a
		_new_assign.add_item(agent.display_name)
		_new_assign.set_item_metadata(_new_assign.item_count - 1, agent.id)
		if prev == agent.id:
			_new_assign.select(_new_assign.item_count - 1)


func _refresh() -> void:
	if _bridge == null or not _active:
		return
	var summ: Dictionary = _bridge.summary_for(_item_id)
	_title.text = "Routines & Chores — %d of %d present · %s" % [
		int(summ.get("count", 0)), int(summ.get("initial_count", 0)),
		str(summ.get("morale_label", "—"))]
	# Walking cost is a scheduling input, not trivia: time spent getting
	# somewhere is time not available for chores.
	var walk_m := float(summ.get("walk_distance_m", 0.0))
	if walk_m > 1.0 and _walk_lbl != null:
		_walk_lbl.text = "Walking today: %.0f m/person · %.0f kcal · %.1f%% of the day — %s" % [
			walk_m, float(summ.get("walk_kcal", 0.0)),
			float(summ.get("walk_overhead", 0.0)) * 100.0,
			str(summ.get("walk_label", ""))]
	elif _walk_lbl != null:
		_walk_lbl.text = ""
	_refresh_weather()
	_refresh_roster()
	_refresh_chores()


func _refresh_weather() -> void:
	var w: Dictionary = _bridge.current_weather()
	if w.is_empty():
		_weather_lbl.text = ""
		return
	_weather_lbl.text = "%.0f °C · %.0f m/s wind · %.1f mm/h rain — %s" % [
		NpcWeatherGate.temp_c(w), NpcWeatherGate.wind_ms(w), NpcWeatherGate.rain_mmh(w),
		NpcWeatherGate.describe(w)]


func _refresh_roster() -> void:
	for c in _roster_box.get_children():
		c.queue_free()
	var board := _board()
	var abs_h: float = _bridge.current_abs_hours()
	for a in _bridge.roster_for(_item_id):
		var agent: NpcAgent = a
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		_roster_box.add_child(row)

		var name_lbl := Label.new()
		name_lbl.text = agent.display_name
		name_lbl.custom_minimum_size.x = 90
		name_lbl.add_theme_font_size_override("font_size", 12)
		name_lbl.add_theme_color_override("font_color", C_TEXT)
		row.add_child(name_lbl)

		var mood := Label.new()
		mood.text = agent.morale_band_label()
		mood.custom_minimum_size.x = 110
		mood.add_theme_font_size_override("font_size", 11)
		mood.add_theme_color_override("font_color", NpcMorale.color(agent.morale))
		row.add_child(mood)

		var assigned := 0.0
		if board != null:
			assigned = board.assigned_hours_for(agent.id, abs_h)
		row.add_child(_day_plan_strip(agent, assigned))

		var status := Label.new()
		status.text = agent.status_line()
		status.custom_minimum_size.x = 150
		status.add_theme_font_size_override("font_size", 10)
		status.add_theme_color_override("font_color", C_TEXT_DIM)
		row.add_child(status)


## The affordance that makes over-scheduling visible: sleep / needs / chores /
## free time as one 24 h bar. When chores exceed the day, the overflow shows
## in red — the person is booked past what they can physically do.
func _day_plan_strip(agent: NpcAgent, assigned_h: float) -> Control:
	var strip := HBoxContainer.new()
	strip.add_theme_constant_override("separation", 0)
	strip.custom_minimum_size = Vector2(240, 16)
	strip.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var sleep_h := 24.0 - NpcAgent.SLEEP_START_H + NpcAgent.SLEEP_END_H
	var free_before := agent.free_hours(0.0)
	var need_h := maxf(24.0 - sleep_h - free_before, 0.0)
	var chore_h := minf(assigned_h, maxf(free_before, 0.0))
	var over_h := maxf(assigned_h - free_before, 0.0)
	var free_h := maxf(free_before - chore_h, 0.0)

	for seg in [[sleep_h, C_SLEEP], [need_h, C_NEEDS], [chore_h, C_CHORE],
			[free_h, C_FREE], [over_h, C_OVER]]:
		var hours := float((seg as Array)[0])
		if hours <= 0.01:
			continue
		var bar := ColorRect.new()
		bar.color = (seg as Array)[1] as Color
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bar.size_flags_stretch_ratio = hours
		strip.add_child(bar)
	strip.tooltip_text = "sleep %.1f h · needs %.1f h · chores %.1f h · free %.1f h%s" % [
		sleep_h, need_h, chore_h, free_h,
		"  ⚠ OVER-SCHEDULED by %.1f h" % over_h if over_h > 0.01 else ""]
	return strip


func _refresh_chores() -> void:
	for c in _chore_box.get_children():
		c.queue_free()
	var board := _board()
	if board == null:
		return
	if board.chores.is_empty():
		var empty := Label.new()
		empty.text = "No chores yet. Work keeps the infrastructure running —\nand people with nothing to do still need somewhere to gather."
		empty.add_theme_font_size_override("font_size", 11)
		empty.add_theme_color_override("font_color", C_TEXT_DIM)
		_chore_box.add_child(empty)
		return
	var abs_h: float = _bridge.current_abs_hours()
	var weather: Dictionary = _bridge.current_weather()
	for c in board.chores:
		var chore: Dictionary = c
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		_chore_box.add_child(row)

		var lbl := Label.new()
		lbl.text = str(chore.get("label", "?"))
		lbl.custom_minimum_size.x = 150
		lbl.add_theme_font_size_override("font_size", 12)
		lbl.add_theme_color_override("font_color", C_TEXT)
		row.add_child(lbl)

		var bar := ProgressBar.new()
		bar.min_value = 0.0
		bar.max_value = maxf(float(chore.get("chore_hours", 1.0)), 0.01)
		bar.value = float(chore.get("progress_h", 0.0))
		bar.custom_minimum_size = Vector2(90, 14)
		bar.show_percentage = false
		row.add_child(bar)

		var w: Dictionary = chore.get("window", {})
		var meta := Label.new()
		var exposure := str(chore.get("exposure", "outdoor"))
		var gated := NpcWeatherGate.is_unsafe(weather, exposure)
		meta.text = "%.0f h · %02d–%02d%s" % [
			float(chore.get("chore_hours", 0.0)),
			int(w.get("start_h", 0)), int(w.get("end_h", 24)),
			"  ⛔ weather" if gated else ""]
		meta.add_theme_font_size_override("font_size", 10)
		meta.add_theme_color_override("font_color",
				UITheme.C_WARN if gated else C_TEXT_DIM)
		meta.custom_minimum_size.x = 130
		row.add_child(meta)

		var who := Label.new()
		var assigned := str(chore.get("assigned_to", ""))
		who.text = _name_for(assigned) if not assigned.is_empty() else "anyone"
		who.add_theme_font_size_override("font_size", 10)
		who.add_theme_color_override("font_color", C_TEXT_DIM)
		who.custom_minimum_size.x = 80
		row.add_child(who)

		var del := Button.new()
		del.text = "✕"
		var cid := str(chore.get("id", ""))
		del.pressed.connect(func() -> void:
			var b := _board()
			if b != null:
				b.remove_chore(cid)
			_refresh())
		row.add_child(del)


func _name_for(agent_id: String) -> String:
	if agent_id.is_empty():
		return "anyone"
	var agent: NpcAgent = _bridge.find_agent(agent_id)
	return agent.display_name if agent != null else agent_id


func _on_add_chore() -> void:
	var board := _board()
	if board == null:
		return
	var exposure := str(NpcWeatherGate.EXPOSURES[maxi(_new_exposure.selected, 0)])
	var assign := ""
	if _new_assign.selected > 0:
		assign = str(_new_assign.get_selected_metadata())
	board.add_chore(_new_label.text.strip_edges(), float(_new_hours.value), {
		"window": {"start_h": float(_new_start.value), "end_h": float(_new_end.value)},
		"exposure": str(exposure),
		"assigned_to": assign,
	})
	_new_label.text = ""
	_refresh()
