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

# --- routine editor ---------------------------------------------------------
var _routine_strip: Control = null
var _routine_rows: VBoxContainer = null
var _routine_status: Label = null
## Working copy. Edits are staged here and only reach the sim on Apply, so a
## half-finished day (a gap mid-edit, an overlap) never drives behaviour.
var _draft: Array = []


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
	_load_routine_draft()
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

	# Right: tabs — the chore board, and the daily schedule everyone follows.
	# Tabbed rather than stacked because the routine editor needs real room:
	# it is a list of blocks covering the whole 24 h, not a couple of fields.
	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(tabs)

	var right := VBoxContainer.new()
	right.name = "Chores"
	right.add_theme_constant_override("separation", 4)
	tabs.add_child(right)
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

	var routine_tab := VBoxContainer.new()
	routine_tab.name = "Daily routine"
	routine_tab.add_theme_constant_override("separation", 4)
	tabs.add_child(routine_tab)
	_build_routine_tab(routine_tab)


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


# ---------------------------------------------------------------------------
# Daily routine editor
# ---------------------------------------------------------------------------

## Colour per block kind, shared by the strip and the row swatches so the two
## readings of the same day agree at a glance.
static func _kind_color(kind: String) -> Color:
	match kind:
		NpcRoutine.SLEEP: return C_SLEEP
		NpcRoutine.BATHROOM: return Color(0.36, 0.72, 0.86)
		NpcRoutine.EAT: return Color(0.90, 0.66, 0.32)
		NpcRoutine.WASH: return Color(0.42, 0.78, 0.74)
		NpcRoutine.ENRICHMENT: return Color(0.78, 0.46, 0.84)
		NpcRoutine.WORK: return C_CHORE
	return C_FREE


func _build_routine_tab(parent: VBoxContainer) -> void:
	parent.add_child(_section_label("The day everyone follows"))
	var hint := Label.new()
	hint.text = "Each person is shifted up to 30 min either way, so the camp does not move in lockstep. Needs still interrupt: someone desperately thirsty leaves a work block and comes back to it."
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", C_TEXT_DIM)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(hint)

	_routine_strip = Control.new()
	_routine_strip.custom_minimum_size.y = 34
	_routine_strip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_routine_strip.draw.connect(_draw_routine_strip)
	parent.add_child(_routine_strip)

	_routine_status = Label.new()
	_routine_status.add_theme_font_size_override("font_size", 11)
	_routine_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(_routine_status)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(scroll)
	_routine_rows = VBoxContainer.new()
	_routine_rows.add_theme_constant_override("separation", 2)
	_routine_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_routine_rows)

	var btns := HBoxContainer.new()
	btns.add_theme_constant_override("separation", 6)
	parent.add_child(btns)
	var add := Button.new()
	add.text = "Add block"
	add.pressed.connect(_on_routine_add)
	btns.add_child(add)
	var reset := Button.new()
	reset.text = "Reset to default day"
	reset.pressed.connect(func() -> void:
		_draft = NpcRoutine.default_day().to_array()
		_refresh_routine())
	btns.add_child(reset)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btns.add_child(spacer)
	var apply := Button.new()
	apply.text = "Apply"
	apply.tooltip_text = "Everyone picks the new day up at their next idle moment. The roster is not restarted."
	apply.pressed.connect(_on_routine_apply)
	btns.add_child(apply)


## Pull the live schedule into the draft, so the editor always opens showing
## what people are actually doing rather than a template.
func _load_routine_draft() -> void:
	var r: NpcRoutine = null
	if _bridge != null and _bridge.has_method("routine_for"):
		r = _bridge.call("routine_for", _item_id)
	if r == null:
		r = NpcRoutine.default_day()
	_draft = r.to_array()
	_refresh_routine()


func _refresh_routine() -> void:
	if _routine_rows == null:
		return
	for c in _routine_rows.get_children():
		c.queue_free()
	for i in range(_draft.size()):
		_routine_rows.add_child(_routine_row(i))
	_update_routine_status()
	if _routine_strip != null:
		_routine_strip.queue_redraw()


func _routine_row(idx: int) -> HBoxContainer:
	var b: Dictionary = _draft[idx]
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)

	var swatch := ColorRect.new()
	swatch.color = _kind_color(str(b.get("kind", NpcRoutine.FREE)))
	swatch.custom_minimum_size = Vector2(10, 20)
	row.add_child(swatch)

	var kind_opt := OptionButton.new()
	for k in NpcRoutine.KINDS:
		kind_opt.add_item(str(NpcRoutine.LABELS.get(k, k)))
	kind_opt.selected = maxi(NpcRoutine.KINDS.find(str(b.get("kind", NpcRoutine.FREE))), 0)
	kind_opt.custom_minimum_size.x = 118
	kind_opt.item_selected.connect(func(sel: int) -> void:
		(_draft[idx] as Dictionary)["kind"] = str(NpcRoutine.KINDS[sel])
		_refresh_routine())
	row.add_child(kind_opt)

	# Times are edited in MINUTES past midnight: a 5-minute bathroom block is
	# unreachable on an hours spinner.
	row.add_child(_time_spin(idx, "start_h"))
	var arrow := Label.new()
	arrow.text = "to"
	arrow.add_theme_color_override("font_color", C_TEXT_DIM)
	row.add_child(arrow)
	row.add_child(_time_spin(idx, "end_h"))

	var dur := Label.new()
	var d := float(b.get("end_h", 0.0)) - float(b.get("start_h", 0.0))
	if d < 0.0:
		d += 24.0
	dur.text = ("%d min" % int(round(d * 60.0))) if d < 1.0 else ("%.2f h" % d)
	dur.add_theme_font_size_override("font_size", 11)
	dur.add_theme_color_override("font_color", C_TEXT_DIM)
	dur.custom_minimum_size.x = 56
	row.add_child(dur)

	var del := Button.new()
	del.text = "X"
	del.tooltip_text = "Remove this block"
	del.pressed.connect(func() -> void:
		_draft.remove_at(idx)
		_refresh_routine())
	row.add_child(del)
	return row


func _time_spin(idx: int, key: String) -> SpinBox:
	var sp := SpinBox.new()
	sp.min_value = 0
	sp.max_value = 24 * 60 - 1
	sp.step = 5
	sp.value = round(float((_draft[idx] as Dictionary).get(key, 0.0)) * 60.0)
	sp.custom_minimum_size.x = 84
	sp.prefix = ""
	sp.tooltip_text = "Minutes past midnight (currently %s)" % NpcRoutine.format_hour(
			float((_draft[idx] as Dictionary).get(key, 0.0)))
	sp.value_changed.connect(func(v: float) -> void:
		(_draft[idx] as Dictionary)[key] = v / 60.0
		_refresh_routine())
	return sp


## Whether the draft is a usable day. An untiled routine is not an ERROR —
## uncovered hours fall back to need-driven behaviour, which is exactly what
## the sim did before routines existed — but it is worth surfacing, because a
## gap is usually a typo rather than an intention.
func _update_routine_status() -> void:
	if _routine_status == null:
		return
	var r := NpcRoutine.from_array(_draft)
	var covered := 0
	var overlaps := 0
	for i in range(24 * 12):
		var h := float(i) / 12.0
		var hits := 0
		for b_v in _draft:
			if NpcRoutine._covers(b_v as Dictionary, h):
				hits += 1
		if hits > 0:
			covered += 1
		if hits > 1:
			overlaps += 1
	var gap_h := (1.0 - float(covered) / float(24 * 12)) * 24.0
	var visits := r.toilet_visits_per_day()
	var parts: PackedStringArray = PackedStringArray()
	parts.append("%d bathroom visits, %.0f L flush water per person per day" % [
		visits, r.water_per_visit_l() * float(visits)])
	parts.append("sleep %.1f h, work %.1f h" % [
		r.hours_of(NpcRoutine.SLEEP), r.hours_of(NpcRoutine.WORK)])
	var col := UITheme.C_OK
	if overlaps > 0:
		parts.append("blocks overlap - the first listed wins")
		col = UITheme.C_WARN
	if gap_h > 0.05:
		parts.append("%.1f h unscheduled - needs decide then" % gap_h)
		col = UITheme.C_WARN
	_routine_status.text = "   ".join(parts)
	_routine_status.add_theme_color_override("font_color", col)


func _draw_routine_strip() -> void:
	if _routine_strip == null or _draft.is_empty():
		return
	var w := _routine_strip.size.x
	var h := _routine_strip.size.y
	if w <= 1.0:
		return
	_routine_strip.draw_rect(Rect2(0, 0, w, h), Color(0.10, 0.13, 0.20, 1.0))
	for b_v in _draft:
		var b: Dictionary = b_v
		var s0 := float(b.get("start_h", 0.0))
		var e0 := float(b.get("end_h", 0.0))
		var col := _kind_color(str(b.get("kind", NpcRoutine.FREE)))
		# A block that wraps midnight draws as two pieces, which is also how it
		# reads on a clock.
		if e0 >= s0:
			_routine_strip.draw_rect(Rect2(w * s0 / 24.0, 0, w * (e0 - s0) / 24.0, h), col)
		else:
			_routine_strip.draw_rect(Rect2(w * s0 / 24.0, 0, w * (24.0 - s0) / 24.0, h), col)
			_routine_strip.draw_rect(Rect2(0, 0, w * e0 / 24.0, h), col)
	var fnt := ThemeDB.fallback_font
	for hh in range(25):
		var x := w * float(hh) / 24.0
		var tall := hh % 6 == 0
		_routine_strip.draw_line(Vector2(x, h - (10.0 if tall else 5.0)), Vector2(x, h),
				Color(1, 1, 1, 0.45 if tall else 0.2), 1.0)
		if tall and hh < 24:
			_routine_strip.draw_string(fnt, Vector2(x + 3, 12), "%02d:00" % hh,
					HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(1, 1, 1, 0.55))


func _on_routine_add() -> void:
	_draft.append({"start_h": 12.0, "end_h": 13.0, "kind": NpcRoutine.WORK})
	_refresh_routine()


func _on_routine_apply() -> void:
	if _bridge == null or not _bridge.has_method("set_routine"):
		return
	if _bridge.call("set_routine", _item_id, _draft):
		_load_routine_draft()   # read back whatever the sim actually accepted
