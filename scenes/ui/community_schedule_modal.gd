extends Node

## The Community schedule (NPC life pass, Phase 8): one window for when things
## happen and who does what.
##   - Day: a row per person, midnight to midnight, their own day (their
##     chronotype's night, meals, work blocks) with their rota shifts over it,
##     and a Site row of the day's events. Click the ruler to move the clock.
##   - Week: a row per day of everything scheduled (ScheduledEvents): deploy
##     and drive events, burns, venue sets, meals, optionally the crew shifts.
##     Drag a deploy flag, a burn or a set to retime it (routed to its owner);
##     "New event" adds one.
##   - Person: one person's week, planned against worked hours, their profile
##     (chronotype, sleep, hours, what work they like), editable.
##   - Work: the week's recurring work and who the rota named.
##   - Balance: planned and worked hours per person, how evenly spread.
## Footer: export calendars (.ics, one for the group and one per person).
## Opened from the timeline's people button, the Routines panel and the Site
## Projects panel: TimelineUI.open_community_schedule(tab, opts).

const TABS := ["Day", "Week", "Person", "Work", "Balance"]
const DAY_KIND_COLORS := {
	"sleep": Color(0.22, 0.27, 0.48), "bathroom": Color(0.46, 0.70, 0.80),
	"eat": Color(0.95, 0.80, 0.36), "wash": Color(0.40, 0.74, 0.86),
	"enrichment": Color(0.74, 0.50, 0.95), "work": Color(0.33, 0.55, 0.80),
	"free": Color(0.30, 0.34, 0.42), "social": Color(0.84, 0.52, 0.66),
	"shift": Color(0.45, 0.80, 0.98),
}
const REFRESH_S := 4.0

var _frame: ModalFrame = null
var _tab := "Day"
var _tab_btns := {}
var _pages := {}
var _hab := ""
var _hab_opt: OptionButton = null
var _day := 0            # the Day tab's calendar day (day index)
var _week0 := 0          # the Week tab's first day
var _person := ""
var _info: Label = null
var _status: Label = null
var _day_label: Label = null
var _week_label: Label = null
var _day_gantt: GanttRows = null
var _week_gantt: GanttRows = null
var _person_gantt: GanttRows = null
var _person_opt: OptionButton = null
var _person_tiles: StatTiles = null
var _person_form: VBoxContainer = null
var _work_box: VBoxContainer = null
var _balance_box: VBoxContainer = null
var _show_shifts: CheckBox = null
var _show_meals: CheckBox = null
var _sel_event: Dictionary = {}
var _sel_box: HBoxContainer = null
var _new_kind: OptionButton = null
var _new_target: OptionButton = null
var _new_hour: SpinBox = null
var _new_len: SpinBox = null
var _new_label: LineEdit = null
var _new_for: Label = null
var _profile_edit: Dictionary = {}
var _refresh_t := 0.0
var _events: Array = []


func open(tab: String = "", opts: Dictionary = {}) -> void:
	if _frame == null:
		_build()
	var now := ScheduleSources.now_h()
	_day = ScheduledEvents.day_of(now)
	_week0 = _day
	if opts.has("habitat"):
		_hab = str(opts["habitat"])
	if opts.has("person"):
		_person = str(opts["person"])
	_fill_habitats()
	_set_tab(tab if TABS.has(tab) else _tab)
	_frame.open()


func is_open() -> bool:
	return _frame != null and _frame.is_open()


func close() -> void:
	if _frame != null:
		_frame.close()


func current_tab() -> String:
	return _tab


func day_gantt() -> GanttRows:
	return _day_gantt


func week_gantt() -> GanttRows:
	return _week_gantt


func events() -> Array:
	return _events


func habitat() -> String:
	return _hab


func _process(delta: float) -> void:
	if not is_open():
		return
	var now := ScheduleSources.now_h()
	for g in [_day_gantt, _week_gantt, _person_gantt]:
		if g != null:
			(g as GanttRows).set_now(now)
	_refresh_t += delta
	if _refresh_t >= REFRESH_S:
		for g in [_day_gantt, _week_gantt, _person_gantt]:
			if g != null and (g as GanttRows).is_busy():
				return
		# Never rebuild a form the player is typing in.
		var fo := _frame.get_viewport().gui_get_focus_owner() if _frame.get_viewport() != null else null
		if fo != null and (fo is LineEdit or fo is SpinBox or (fo.get_parent() is SpinBox)):
			return
		if _tab == "Person":
			return   # the profile form holds unapplied edits
		_refresh_t = 0.0
		_refresh_tab()


# --- building ---------------------------------------------------------------------

func _build() -> void:
	_frame = ModalFrame.create("Community schedule",
		"When things happen and who does what: everyone's day, the week's events, the rota.",
		Vector2(1280, 900), "community_schedule")
	_frame.content_max_w = 0.0
	add_child(_frame)
	var b := _frame.body
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 6)
	b.add_child(top)
	for t in TABS:
		var bt := Button.new()
		bt.text = t
		bt.name = "tab_%s" % str(t).to_lower()
		bt.toggle_mode = true
		UITheme.style_button(bt)
		var tt := str(t)
		bt.pressed.connect(func() -> void: _set_tab(tt))
		top.add_child(bt)
		_tab_btns[t] = bt
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(sp)
	var hl := Label.new()
	hl.text = "Camp"
	hl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	top.add_child(hl)
	_hab_opt = OptionButton.new()
	_hab_opt.name = "habitat"
	_hab_opt.custom_minimum_size.x = 220
	_hab_opt.item_selected.connect(func(i: int) -> void:
		_hab = str(_hab_opt.get_item_metadata(i))
		_person = ""
		_refresh_tab())
	top.add_child(_hab_opt)

	_info = Label.new()
	_info.name = "info"
	_info.text = " "
	_info.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	b.add_child(_info)

	_pages["Day"] = _build_day()
	_pages["Week"] = _build_week()
	_pages["Person"] = _build_person()
	_pages["Work"] = _build_work()
	_pages["Balance"] = _build_balance()
	for k in _pages:
		b.add_child(_pages[k])

	_status = Label.new()
	_status.name = "status"
	_status.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# One line: a wrapping label in the footer row has no width of its own
	# and grew tall enough to push the buttons off the screen.
	_status.clip_text = true
	_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_status.custom_minimum_size.x = 120
	_status.mouse_filter = Control.MOUSE_FILTER_PASS
	_frame.footer.add_child(_status)
	var ex := _frame.add_button("Export calendars (.ics)", ModalFrame.SECONDARY, _export,
		"Write the group calendar and one per person for the next 7 days to user://schedule_export/. Import into any calendar app; re-importing updates the events.")
	ex.name = "export_ics"
	var of := _frame.add_button("Open folder", ModalFrame.SECONDARY, _open_folder,
		"Show the exported calendars")
	of.name = "open_folder"
	_frame.add_button("Close", ModalFrame.PRIMARY, _frame.close)


func _nav_row(prev_cb: Callable, today_cb: Callable, next_cb: Callable, unit: String) -> Array:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var p := Button.new()
	p.text = "◀"
	p.tooltip_text = "Previous %s" % unit
	UITheme.style_button(p)
	p.pressed.connect(prev_cb)
	row.add_child(p)
	var t := Button.new()
	t.text = "Today"
	UITheme.style_button(t)
	t.pressed.connect(today_cb)
	row.add_child(t)
	var n := Button.new()
	n.text = "▶"
	n.tooltip_text = "Next %s" % unit
	UITheme.style_button(n)
	n.pressed.connect(next_cb)
	row.add_child(n)
	var lbl := Label.new()
	lbl.add_theme_font_size_override("font_size", UITheme.FONT_MD)
	row.add_child(lbl)
	return [row, lbl]


func _build_day() -> Control:
	var v := VBoxContainer.new()
	v.name = "page_day"
	var nr := _nav_row(_day_prev, _day_today, _day_next, "day")
	v.add_child(nr[0])
	_day_label = nr[1]
	_day_gantt = GanttRows.new()
	_day_gantt.name = "day_gantt"
	_day_gantt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_day_gantt.segment_hovered.connect(_on_hover)
	_day_gantt.segment_clicked.connect(func(row_id: String, seg: Dictionary) -> void:
		if row_id == "site":
			_select_event(seg)
		else:
			_open_person(row_id))
	_day_gantt.row_clicked.connect(func(row_id: String) -> void:
		if row_id != "site":
			_open_person(row_id))
	_day_gantt.time_clicked.connect(_jump_to)
	_day_gantt.segment_moved.connect(_on_moved)
	v.add_child(_day_gantt)
	v.add_child(_legend())
	return v


func _day_prev() -> void:
	_day -= 1
	_refresh_tab()


func _day_today() -> void:
	_day = ScheduledEvents.day_of(ScheduleSources.now_h())
	_refresh_tab()


func _day_next() -> void:
	_day += 1
	_refresh_tab()


func _week_prev() -> void:
	_week0 -= 7
	_refresh_tab()


func _week_today() -> void:
	_week0 = ScheduledEvents.day_of(ScheduleSources.now_h())
	_refresh_tab()


func _week_next() -> void:
	_week0 += 7
	_refresh_tab()


func _legend() -> Control:
	var f := HFlowContainer.new()
	f.add_theme_constant_override("h_separation", 12)
	for k in ["sleep", "eat", "work", "shift", "social", "free", "bathroom", "wash", "enrichment"]:
		var h := HBoxContainer.new()
		var sw := ColorRect.new()
		sw.color = DAY_KIND_COLORS[k]
		sw.custom_minimum_size = Vector2(12, 12)
		sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(sw)
		var l := Label.new()
		l.text = "Rota shift" if k == "shift" else str(NpcRoutine.LABELS.get(k, k))
		l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		l.add_theme_color_override("font_color", UITheme.C_TEXT_S)
		h.add_child(l)
		f.add_child(h)
	return f


func _build_week() -> Control:
	var v := VBoxContainer.new()
	v.name = "page_week"
	var nr := _nav_row(_week_prev, _week_today, _week_next, "week")
	v.add_child(nr[0])
	_week_label = nr[1]
	var opts := HBoxContainer.new()
	opts.add_theme_constant_override("separation", 12)
	(nr[0] as HBoxContainer).add_child(opts)
	_show_meals = CheckBox.new()
	_show_meals.text = "Meals"
	_show_meals.name = "show_meals"
	_show_meals.button_pressed = true
	_show_meals.toggled.connect(func(_on: bool) -> void: _refresh_tab())
	opts.add_child(_show_meals)
	_show_shifts = CheckBox.new()
	_show_shifts.text = "Crew shifts"
	_show_shifts.name = "show_shifts"
	_show_shifts.toggled.connect(func(_on: bool) -> void: _refresh_tab())
	opts.add_child(_show_shifts)
	_week_gantt = GanttRows.new()
	_week_gantt.name = "week_gantt"
	_week_gantt.label_w = 120.0
	_week_gantt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_week_gantt.segment_hovered.connect(_on_hover)
	_week_gantt.segment_clicked.connect(func(_r: String, seg: Dictionary) -> void: _select_event(seg))
	_week_gantt.segment_moved.connect(_on_moved)
	_week_gantt.time_clicked.connect(_jump_to)
	v.add_child(_week_gantt)
	var hint := Label.new()
	hint.text = "Drag a deploy, drive or burn flag or a venue set to move it (sets move every day's copy). Click an event to jump the clock to it."
	hint.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	hint.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(hint)
	_sel_box = HBoxContainer.new()
	_sel_box.name = "selected"
	_sel_box.add_theme_constant_override("separation", 6)
	v.add_child(_sel_box)
	v.add_child(SectionHeader.make("New event", "calendar"))
	var nr2 := HBoxContainer.new()
	nr2.add_theme_constant_override("separation", 6)
	v.add_child(nr2)
	_new_kind = OptionButton.new()
	_new_kind.name = "new_kind"
	for it in [["deploy", "Deploy (crews build)"], ["packup", "Pack up"], ["arrive", "Arrive"],
			["leave", "Leave"], ["set", "Set at a venue"], ["burn", "Burn a structure"]]:
		_new_kind.add_item(str(it[1]))
		_new_kind.set_item_metadata(_new_kind.item_count - 1, it[0])
	_new_kind.item_selected.connect(func(_i: int) -> void: _fill_new_targets())
	nr2.add_child(_new_kind)
	_new_target = OptionButton.new()
	_new_target.name = "new_target"
	_new_target.custom_minimum_size.x = 180
	nr2.add_child(_new_target)
	var dl := Label.new()
	dl.text = "day"
	nr2.add_child(dl)
	var dayo := OptionButton.new()
	dayo.name = "new_day"
	nr2.add_child(dayo)
	var at := Label.new()
	at.text = "at"
	nr2.add_child(at)
	_new_hour = SpinBox.new()
	_new_hour.name = "new_hour"
	_new_hour.min_value = 0.0
	_new_hour.max_value = 23.75
	_new_hour.step = 0.25
	_new_hour.value = 20.0
	_new_hour.suffix = "h"
	nr2.add_child(_new_hour)
	_new_for = Label.new()
	_new_for.text = "for"
	nr2.add_child(_new_for)
	_new_len = SpinBox.new()
	_new_len.name = "new_len"
	_new_len.min_value = 0.25
	_new_len.max_value = 12.0
	_new_len.step = 0.25
	_new_len.value = 2.0
	_new_len.suffix = "h"
	nr2.add_child(_new_len)
	_new_label = LineEdit.new()
	_new_label.name = "new_label"
	_new_label.placeholder_text = "Name (a set)"
	_new_label.custom_minimum_size.x = 140
	nr2.add_child(_new_label)
	var add := Button.new()
	add.text = "Add"
	add.name = "new_add"
	UITheme.style_button(add)
	add.pressed.connect(func() -> void: _add_event(dayo))
	nr2.add_child(add)
	v.set_meta("day_opt", dayo)
	return v


func _build_person() -> Control:
	var v := VBoxContainer.new()
	v.name = "page_person"
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	v.add_child(row)
	var l := Label.new()
	l.text = "Person"
	row.add_child(l)
	_person_opt = OptionButton.new()
	_person_opt.name = "person"
	_person_opt.custom_minimum_size.x = 220
	_person_opt.item_selected.connect(func(i: int) -> void:
		_person = str(_person_opt.get_item_metadata(i))
		_refresh_tab())
	row.add_child(_person_opt)
	_person_tiles = StatTiles.make(4)
	v.add_child(_person_tiles)
	v.add_child(SectionHeader.make("Their week", "calendar", "their own day, with the rota's shifts over it"))
	_person_gantt = GanttRows.new()
	_person_gantt.name = "person_gantt"
	_person_gantt.label_w = 120.0
	_person_gantt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_person_gantt.segment_hovered.connect(_on_hover)
	_person_gantt.time_clicked.connect(_jump_to)
	v.add_child(_person_gantt)
	v.add_child(SectionHeader.make("Profile", "users",
		"stand in for a real member: their sleep, their limits, what they like doing"))
	_person_form = VBoxContainer.new()
	_person_form.name = "profile"
	v.add_child(_person_form)
	return v


func _build_work() -> Control:
	var v := VBoxContainer.new()
	v.name = "page_work"
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	v.add_child(row)
	var re := Button.new()
	re.text = "Plan the week again"
	re.name = "replan"
	re.tooltip_text = "Re-run the rota now (it also runs once a day by itself)"
	UITheme.style_button(re)
	re.pressed.connect(func() -> void:
		var b := ScheduleSources.bridge()
		if b != null and not _hab.is_empty():
			b.replan_rota(_hab)
		_refresh_tab())
	row.add_child(re)
	var board := Button.new()
	board.text = "Chores & duties…"
	board.name = "open_board"
	board.tooltip_text = "Edit the recurring chores and duties the rota plans"
	UITheme.style_button(board)
	board.pressed.connect(_open_routines)
	row.add_child(board)
	_work_box = VBoxContainer.new()
	_work_box.name = "work_list"
	v.add_child(_work_box)
	return v


func _build_balance() -> Control:
	var v := VBoxContainer.new()
	v.name = "page_balance"
	_balance_box = VBoxContainer.new()
	_balance_box.name = "balance"
	v.add_child(_balance_box)
	return v


# --- state ---------------------------------------------------------------------------

func _fill_habitats() -> void:
	_hab_opt.clear()
	var habs := ScheduleSources.habitats()
	var pick := -1
	for i in habs.size():
		var h: Dictionary = habs[i]
		_hab_opt.add_item("%s%s" % [str(h["name"]), " (crowd)" if bool(h["light"]) else ""])
		_hab_opt.set_item_metadata(i, str(h["id"]))
		if str(h["id"]) == _hab:
			pick = i
	if pick < 0 and not habs.is_empty():
		pick = 0
		# The first camp with people simulated in full detail.
		for i in habs.size():
			if not bool((habs[i] as Dictionary)["light"]):
				pick = i
				break
		_hab = str((habs[pick] as Dictionary)["id"])
	if pick >= 0:
		_hab_opt.select(pick)
	_hab_opt.disabled = habs.size() < 2


func _set_tab(t: String) -> void:
	_tab = t
	if _info != null:
		_info.text = " "
	for k in _tab_btns:
		(_tab_btns[k] as Button).button_pressed = k == t
	for k in _pages:
		(_pages[k] as Control).visible = k == t
	_refresh_tab()


func _refresh_tab() -> void:
	if _frame == null:
		return
	match _tab:
		"Day":
			_refresh_day()
		"Week":
			_refresh_week()
		"Person":
			_refresh_person()
		"Work":
			_refresh_work()
		"Balance":
			_refresh_balance()


func _date_text(day: int) -> String:
	var d := IcsWriter.date_of(float(day) * 24.0)
	var wd: String = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"][posmod(NpcChoreBoard.weekday_of_day(day), 7)]
	return "%s %d %s %d" % [wd, d.day, ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug",
		"Sep", "Oct", "Nov", "Dec"][d.month - 1], d.year]


func _people() -> Array:
	var ps := ScheduleSources.people(_hab)
	ps.sort_custom(func(a, b) -> bool: return str(a["name"]) < str(b["name"]))
	return ps


func _seg_from_event(e: Dictionary, t0: float) -> Array:
	# Split a span at midnight so each day row gets its part.
	var out: Array = []
	var a := float(e["at_h"])
	var b := float(e["end_h"])
	var col := ScheduledEvents.color_of(str(e["kind"]))
	if b <= a:
		if a >= t0 and a < t0 + 24.0:
			out.append({"a": a, "b": a, "kind": e["kind"], "label": e["label"], "color": col,
				"id": e["id"], "editable": e["editable"], "event": e})
		return out
	var sa := maxf(a, t0)
	var sb := minf(b, t0 + 24.0)
	if sb > sa:
		out.append({"a": sa, "b": sb, "kind": e["kind"], "label": e["label"], "color": col,
			"id": e["id"], "editable": bool(e["editable"]) and is_equal_approx(sa, a), "event": e})
	return out


func _refresh_day() -> void:
	_day_label.text = _date_text(_day)
	var t0 := float(_day) * 24.0
	var r := ScheduleSources.routine_of(_hab)
	var rows: Array = []
	_events = ScheduleSources.gather(t0, t0 + 24.0, {"meals": false, "rota": false})
	var site_segs: Array = []
	for e in _events:
		site_segs.append_array(_seg_from_event(e, t0))
	rows.append({"id": "site", "label": "Site", "sub": UiText.count(site_segs.size(), "event"),
		"t0": t0, "segs": site_segs})
	var ps := _people()
	var b := ScheduleSources.bridge()
	var rota: Dictionary = b.rota_for(_hab) if b != null else {}
	var shifts_all := ScheduledEvents.from_rota(rota, {}, _hab)
	for p in ps:
		var pid := str(p["id"])
		var mine: Array = []
		for s in shifts_all:
			if ((s as Dictionary)["who"] as Array).has(pid):
				mine.append(s)
		var segs := ScheduledEvents.person_day(r, pid, float(p["offset_h"]), _day, mine)
		var by := ScheduledEvents.hours_by_kind(segs)
		for s in segs:
			(s as Dictionary)["color"] = DAY_KIND_COLORS.get(str(s["kind"]), Color(0.5, 0.5, 0.5))
			(s as Dictionary)["id"] = "%s:%s:%.2f" % [pid, str(s["kind"]), float(s["a"])]
		var chrono := NpcPersona.chronotype_label(r.persona_of(pid) if r != null else {})
		var rota_h := float(by.get("shift", 0.0))
		rows.append({"id": pid, "label": str(p["name"]),
			"sub": chrono if rota_h < 0.01 else "%s · rota %s" % [chrono, UiText.duration(rota_h)],
			"t0": t0, "segs": segs})
	if ps.is_empty():
		_status.text = "No simulated people here yet: tag a pop-driven habitat on the graph."
	_day_gantt.set_rows(rows, 24.0)
	_day_gantt.set_now(ScheduleSources.now_h())


func _refresh_week() -> void:
	_week_label.text = "%s – %s" % [_date_text(_week0), _date_text(_week0 + 6)]
	var h0 := float(_week0) * 24.0
	_events = ScheduleSources.gather(h0, h0 + 7.0 * 24.0, {"meals": _show_meals.button_pressed,
		"rota": _show_shifts.button_pressed, "habitat": _hab})
	var rows: Array = []
	for i in 7:
		var t0 := h0 + float(i) * 24.0
		var segs: Array = []
		for e in _events:
			segs.append_array(_seg_from_event(e, t0))
		rows.append({"id": "d%d" % (_week0 + i), "label": _date_text(_week0 + i),
			"sub": UiText.count(segs.size(), "event"), "t0": t0, "segs": segs})
	_week_gantt.set_rows(rows, 24.0)
	_week_gantt.set_now(ScheduleSources.now_h())
	var dayo: OptionButton = (_pages["Week"] as Control).get_meta("day_opt")
	var keep := dayo.selected
	dayo.clear()
	for i in 7:
		dayo.add_item(_date_text(_week0 + i))
		dayo.set_item_metadata(i, _week0 + i)
	dayo.select(clampi(keep, 0, 6))
	_fill_new_targets()
	_refresh_selected()


func _fill_new_targets() -> void:
	if _new_target == null:
		return
	var kind := str(_new_kind.get_item_metadata(_new_kind.selected))
	_new_target.clear()
	var list: Array = []
	if kind == "set":
		list = ScheduleSources.venues()
	elif kind == "burn":
		list = ScheduleSources.burnable_props()
	for it in list:
		_new_target.add_item(str((it as Dictionary)["label"]))
		_new_target.set_item_metadata(_new_target.item_count - 1, str((it as Dictionary)["id"]))
	_new_target.visible = kind == "set" or kind == "burn"
	_new_target.disabled = list.is_empty()
	if list.is_empty() and _new_target.visible:
		_new_target.add_item("none on this site")
	_new_len.visible = kind == "set"
	_new_for.visible = kind == "set"
	_new_label.visible = kind == "set"


func _add_event(dayo: OptionButton) -> void:
	var kind := str(_new_kind.get_item_metadata(_new_kind.selected))
	var day := int(dayo.get_item_metadata(dayo.selected)) if dayo.item_count > 0 else _week0
	var at_h := float(day) * 24.0 + _new_hour.value
	var ok := false
	match kind:
		"set":
			if _new_target.disabled:
				_status.text = "Tag a venue (a stage, a temple, a fire circle) first."
				return
			ok = ScheduleSources.add_set(str(_new_target.get_item_metadata(_new_target.selected)),
				_new_hour.value, _new_len.value, _new_label.text.strip_edges())
		"burn":
			if _new_target.disabled:
				_status.text = "Nothing on this site is burnable: tick Burnable on a structure in the prop editor."
				return
			ok = ScheduleSources.add_burn(str(_new_target.get_item_metadata(_new_target.selected)), at_h)
		_:
			ok = not ScheduleSources.add_deploy(kind, at_h).is_empty()
	_status.text = ("Added: %s at %s." % [ScheduledEvents.word_of(kind),
		NpcRoutine.format_hour(_new_hour.value)]) if ok else "Could not add that event."
	_refresh_tab()


func _select_event(seg: Dictionary) -> void:
	var ev: Dictionary = seg.get("event", {})
	if ev.is_empty():
		ev = ScheduledEvents.find(_events, str(seg.get("id", "")))
	_sel_event = ev
	_refresh_selected()


func _refresh_selected() -> void:
	if _sel_box == null:
		return
	for c in _sel_box.get_children():
		_sel_box.remove_child(c)
		c.queue_free()
	if _sel_event.is_empty():
		return
	var cur := ScheduledEvents.find(_events, str(_sel_event.get("id", "")))
	if cur.is_empty():
		_sel_event = {}
		return
	_sel_event = cur
	var l := Label.new()
	l.text = "%s · %s" % [str(cur["label"]), _when(cur)]
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sel_box.add_child(l)
	var j := Button.new()
	j.text = "Jump the clock here"
	j.name = "sel_jump"
	UITheme.style_button(j)
	j.pressed.connect(func() -> void: _jump_to(float(cur["at_h"])))
	_sel_box.add_child(j)
	if bool(cur.get("editable", false)):
		var mv := Button.new()
		mv.text = "Move to the clock"
		mv.name = "sel_move"
		UITheme.style_button(mv)
		mv.pressed.connect(func() -> void:
			if ScheduleSources.retime(cur, ScheduleSources.now_h()):
				_status.text = "Moved %s to now." % str(cur["label"])
			_refresh_tab())
		_sel_box.add_child(mv)
		var rm := Button.new()
		rm.text = "Remove"
		rm.name = "sel_remove"
		UITheme.style_button(rm)
		rm.pressed.connect(func() -> void:
			if ScheduleSources.remove(cur):
				_status.text = "Removed %s." % str(cur["label"])
			_sel_event = {}
			_refresh_tab())
		_sel_box.add_child(rm)


func _when(ev: Dictionary) -> String:
	var a := float(ev["at_h"])
	var b := float(ev["end_h"])
	var s := "%s %s" % [_date_text(ScheduledEvents.day_of(a)), NpcRoutine.format_hour(fposmod(a, 24.0))]
	if b > a + 1e-6:
		s += "–%s" % NpcRoutine.format_hour(fposmod(b, 24.0))
	return s


func _on_hover(row_id: String, seg: Dictionary) -> void:
	var ev: Dictionary = seg.get("event", {})
	var who := ""
	if not ev.is_empty():
		_info.text = "%s · %s%s" % [str(ev["label"]), _when(ev),
			"" if not bool(ev.get("editable", false)) else "  (drag to move)"]
		return
	for p in _people():
		if str(p["id"]) == row_id:
			who = str(p["name"])
	var a := float(seg.get("a", 0.0))
	var b := float(seg.get("b", a))
	_info.text = "%s%s · %s–%s" % ["%s: " % who if not who.is_empty() else "", str(seg.get("label", "")),
		NpcRoutine.format_hour(fposmod(a, 24.0)), NpcRoutine.format_hour(fposmod(b, 24.0))]


func _on_moved(seg: Dictionary, new_a: float) -> void:
	var ev: Dictionary = seg.get("event", {})
	if ev.is_empty():
		return
	if ScheduleSources.retime(ev, new_a):
		_status.text = "Moved %s to %s." % [str(ev["label"]), _when({"at_h": new_a, "end_h": new_a})]
	else:
		_status.text = "%s follows something else and cannot be moved here." % str(ev["label"])
	_refresh_tab()


func _jump_to(abs_h: float) -> void:
	ScheduleSources.set_now_h(abs_h)
	_status.text = "Clock moved to %s." % _when({"at_h": abs_h, "end_h": abs_h})


func _open_person(pid: String) -> void:
	_person = pid
	_set_tab("Person")


# --- person -----------------------------------------------------------------------------

func _refresh_person() -> void:
	var ps := _people()
	_person_opt.clear()
	var pick := -1
	for i in ps.size():
		_person_opt.add_item(str(ps[i]["name"]))
		_person_opt.set_item_metadata(i, str(ps[i]["id"]))
		if str(ps[i]["id"]) == _person:
			pick = i
	if pick < 0 and not ps.is_empty():
		pick = 0
		_person = str(ps[0]["id"])
	if pick >= 0:
		_person_opt.select(pick)
	for c in _person_form.get_children():
		_person_form.remove_child(c)
		c.queue_free()
	if _person.is_empty():
		_person_gantt.set_rows([], 24.0)
		_person_tiles.set_tiles([])
		return
	var p: Dictionary = {}
	for pp in ps:
		if str(pp["id"]) == _person:
			p = pp
	var r := ScheduleSources.routine_of(_hab)
	var b := ScheduleSources.bridge()
	var today := ScheduledEvents.day_of(ScheduleSources.now_h())
	var rows: Array = []
	var planned := 0.0
	for i in 7:
		var d := today + i
		var t0 := float(d) * 24.0
		var mine := ScheduleSources.shifts_of(_hab, _person, t0, t0 + 24.0)
		var segs := ScheduledEvents.person_day(r, _person, float(p.get("offset_h", 0.0)), d, mine)
		for s in segs:
			(s as Dictionary)["color"] = DAY_KIND_COLORS.get(str(s["kind"]), Color(0.5, 0.5, 0.5))
			if str(s["kind"]) == "shift":
				planned += float(s["b"]) - float(s["a"])
		rows.append({"id": "d%d" % d, "label": _date_text(d), "t0": t0, "segs": segs})
	_person_gantt.set_rows(rows, 24.0)
	_person_gantt.set_now(ScheduleSources.now_h())
	var labour: NpcLabourLog = b.labour_for(_hab) if b != null else null
	var worked := labour.hours_between(_person, today - 7, today - 1) if labour != null else 0.0
	var mean := _mean_planned()
	var persona: Dictionary = r.persona_of(_person) if r != null else NpcPersona.for_id(_person)
	_person_tiles.set_tiles([
		{"caption": "Shifts, next 7 days", "value": UiText.duration(planned),
			"tip": "What the rota has planned for them this week"},
		{"caption": "Worked, last 7 days", "value": UiText.duration(worked),
			"tip": "Hours they actually worked (the labour log)"},
		{"caption": "Camp average", "value": UiText.duration(mean),
			"tip": "Mean planned hours per person this week"},
		{"caption": "Sleeps (today)", "value": _sleep_text(rows[0]["segs"] if not rows.is_empty() else []),
			"tip": "%s, needs %.1f h" % [NpcPersona.chronotype_label(persona), float(persona.get("sleep_need_h", 8.0))]},
	])
	_build_profile(persona)


## Bedtime to waking off their own day: the sleep that runs into midnight
## and the sleep that runs out of it.
func _sleep_text(segs: Array) -> String:
	var wake := NAN
	var bed := NAN
	for s in segs:
		var sd: Dictionary = s
		if str(sd.get("kind", "")) != NpcRoutine.SLEEP:
			continue
		var a := fposmod(float(sd["a"]), 24.0)
		var b := float(sd["b"]) - float(sd["a"]) + a
		if a < 0.01:
			wake = b
		elif b > 23.99:
			bed = a
	if is_nan(wake) or is_nan(bed):
		# A night owl's night can sit wholly inside the day: take the longest.
		var best := 0.0
		for s in segs:
			var sd: Dictionary = s
			var l := float(sd["b"]) - float(sd["a"])
			if str(sd.get("kind", "")) == NpcRoutine.SLEEP and l > best:
				best = l
				bed = fposmod(float(sd["a"]), 24.0)
				wake = fposmod(float(sd["b"]), 24.0)
		if best <= 0.0:
			return "–"
	return "%s–%s" % [NpcRoutine.format_hour(bed), NpcRoutine.format_hour(wake)]


func _aff_cb(fk: String) -> Callable:
	return func(v: float) -> void:
		var a2: Dictionary = _profile_edit.get("affinities", {})
		a2[fk] = v
		_profile_edit["affinities"] = a2


func _mean_planned() -> float:
	var b := ScheduleSources.bridge()
	if b == null:
		return 0.0
	var ph: Dictionary = b.rota_for(_hab).get("planned_h", {})
	var ps := _people()
	if ps.is_empty():
		return 0.0
	var tot := 0.0
	for p in ps:
		tot += float(ph.get(str(p["id"]), 0.0))
	return tot / float(ps.size())


func _build_profile(persona: Dictionary) -> void:
	_profile_edit = {}
	var b := ScheduleSources.bridge()
	var r := ScheduleSources.routine_of(_hab)
	var own: Dictionary = r.personas.get(_person, {}) if r != null else {}
	var fields := [
		["chrono_h", "Body clock", -2.5, 2.5, 0.25, "h", "Hours later (+) or earlier (−) than the camp's night"],
		["sleep_need_h", "Sleep need", 6.5, 9.5, 0.25, "h", "How long they sleep"],
		["max_h_day", "Most work a day", 0.0, 16.0, 0.5, "h", "The rota never plans more"],
		["max_h_week", "Most work a week", 0.0, 80.0, 1.0, "h", "The rota never plans more"],
		["patience_h", "Waits in a line", 0.05, 2.0, 0.05, "h", "How long they queue before trying elsewhere"],
		["sociability", "Sociability", 0.0, 1.0, 0.05, "", "How much they seek company"],
	]
	for f in fields:
		var key := str(f[0])
		var row := FormRow.slider(str(f[1]), float(f[2]), float(f[3]), float(persona.get(key, 0.0)),
			float(f[4]), str(f[5]), func(v: float) -> void: _profile_edit[key] = v, str(f[6]),
			"pf_%s" % key)
		if own.has(key):
			row.set_dirty(true)
		_person_form.add_child(row)
	_person_form.add_child(SectionHeader.make("Work they like", "", "−1 avoids it, +1 seeks it out"))
	var aff: Dictionary = persona.get("affinities", {})
	var grid := GridContainer.new()
	grid.columns = 2
	_person_form.add_child(grid)
	for fam in NpcPersona.FAMILIES:
		var fk := str(fam)
		var row2 := FormRow.slider(str(NpcPersona.FAMILY_LABELS.get(fk, fk.capitalize())), -1.0, 1.0,
			float(aff.get(fk, 0.0)), 0.1, "", _aff_cb(fk), "", "pa_%s" % fk)
		row2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(row2)
	var skills: Dictionary = b.skills_for(_hab).tags_of(_person) if b != null and b.skills_for(_hab) != null else {}
	var sk: Array = []
	for t in skills:
		sk.append(NpcSkills.label(str(t)))
	_person_form.add_child(FormRow.value("Skills", ", ".join(sk) if not sk.is_empty() else "none yet",
		"Learned by doing supervised work; edited in the Routines panel"))
	var un: Array = persona.get("unavailable", [])
	_person_form.add_child(FormRow.value("Unavailable", UiText.count(un.size(), "block") if not un.is_empty() else "never",
		"Hours the rota keeps them free"))
	var btns := HBoxContainer.new()
	btns.add_theme_constant_override("separation", 6)
	_person_form.add_child(btns)
	var ap := Button.new()
	ap.text = "Apply and plan the week"
	ap.name = "profile_apply"
	UITheme.style_button(ap)
	ap.pressed.connect(_apply_profile)
	btns.add_child(ap)
	var rs := Button.new()
	rs.text = "Back to generated"
	rs.name = "profile_reset"
	rs.tooltip_text = "Forget your edits to this person"
	UITheme.style_button(rs)
	rs.pressed.connect(func() -> void:
		var bb := ScheduleSources.bridge()
		if bb != null:
			bb.set_persona(_hab, _person, {})
			bb.replan_rota(_hab)
		_status.text = "Profile back to generated; the week was planned again."
		_refresh_tab())
	btns.add_child(rs)


func _apply_profile() -> void:
	var b := ScheduleSources.bridge()
	var r := ScheduleSources.routine_of(_hab)
	if b == null or r == null or _person.is_empty():
		return
	var own: Dictionary = (r.personas.get(_person, {}) as Dictionary).duplicate(true)
	for k in _profile_edit:
		if k == "affinities":
			var a: Dictionary = (own.get("affinities", {}) as Dictionary).duplicate()
			for f in _profile_edit["affinities"]:
				a[f] = _profile_edit["affinities"][f]
			own["affinities"] = a
		else:
			own[k] = _profile_edit[k]
	b.set_persona(_hab, _person, own)
	b.replan_rota(_hab)
	_status.text = "Profile saved; the week was planned again."
	_refresh_tab()


# --- work + balance ------------------------------------------------------------------------

func _refresh_work() -> void:
	for c in _work_box.get_children():
		_work_box.remove_child(c)
		c.queue_free()
	var b := ScheduleSources.bridge()
	if b == null or _hab.is_empty():
		_work_box.add_child(EmptyState.make("calendar", "No camp is simulated here yet."))
		return
	var rota := b.rota_for(_hab)
	var items := b.rota_items(_hab)
	var shifts: Dictionary = rota.get("shifts", {})
	var names := ScheduleSources.names_of(_hab)
	var covered := 0
	var short := 0
	var none := 0
	var hours := 0.0
	var rows: Array = []
	for it in items:
		var key := str(it["key"])
		var sh: Dictionary = shifts.get(key, {})
		var crew: Array = sh.get("agents", [])
		var want := int(it.get("crew", 1))
		var state := "covered"
		if crew.is_empty():
			state = "unassigned"
			none += 1
		elif crew.size() < want:
			state = "short"
			short += 1
		else:
			covered += 1
		hours += float(it.get("hours", 0.0))
		rows.append([int(it["day"]), it, sh, crew, state])
	# Jobs nobody could take first, then short-handed, then by day and time.
	var rank := {"unassigned": 0, "short": 1, "covered": 2}
	rows.sort_custom(func(a, c) -> bool:
		if int(rank[str(a[4])]) != int(rank[str(c[4])]):
			return int(rank[str(a[4])]) < int(rank[str(c[4])])
		if int(a[0]) != int(c[0]):
			return int(a[0]) < int(c[0])
		return float((a[2] as Dictionary).get("start_h", 99.0)) < float((c[2] as Dictionary).get("start_h", 99.0)))
	var tiles := StatTiles.make(4)
	_work_box.add_child(tiles)
	tiles.set_tiles([
		{"caption": "Recurring jobs, 7 days", "value": str(items.size())},
		{"caption": "Crewed", "value": str(covered), "level": "ok"},
		{"caption": "Short-handed", "value": str(short), "level": "warn" if short > 0 else "muted"},
		{"caption": "Nobody free", "value": str(none), "level": "error" if none > 0 else "muted",
			"tip": "Left on the open board for whoever is free"},
	])
	var per := hours / maxf(float(names.size()), 1.0)
	var note := Label.new()
	note.text = "%.0f person-hours of recurring work this week, %s per person. One-off jobs, machine steps and builds stay on the open board." % [
		hours, UiText.duration(per)]
	note.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_work_box.add_child(note)
	if items.is_empty():
		_work_box.add_child(EmptyState.make("calendar",
			"No recurring chores or duties yet. Add some on the chore board and the rota will plan them.",
			"Chores & duties…", _open_routines))
		return
	var grid := GridContainer.new()
	grid.columns = 5
	grid.add_theme_constant_override("h_separation", 14)
	_work_box.add_child(grid)
	for h in ["Day", "When", "Job", "Hours", "Who"]:
		var hl := Label.new()
		hl.text = h
		hl.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		grid.add_child(hl)
	for row in rows:
		var it: Dictionary = row[1]
		var sh: Dictionary = row[2]
		var crew: Array = row[3]
		var st := str(row[4])
		var cells := [_date_text(int(row[0])),
			"%s–%s" % [NpcRoutine.format_hour(float(sh["start_h"])), NpcRoutine.format_hour(float(sh["end_h"]))] if not sh.is_empty() else "–",
			str(it.get("label", "")), UiText.duration(float(it.get("hours", 0.0)))]
		var who: Array = []
		for a in crew:
			who.append(str(names.get(str(a), str(a))))
		var wtxt := ", ".join(who) if not who.is_empty() else "nobody free — open board"
		if st == "short":
			wtxt += "  (short: %d of %d)" % [crew.size(), int(it.get("crew", 1))]
		cells.append(wtxt)
		for k in cells.size():
			var l := Label.new()
			l.text = str(cells[k])
			if k == 4:
				l.add_theme_color_override("font_color", UITheme.C_ERROR if st == "unassigned"
					else (UITheme.C_WARN if st == "short" else UITheme.C_TEXT))
			grid.add_child(l)


func _refresh_balance() -> void:
	for c in _balance_box.get_children():
		_balance_box.remove_child(c)
		c.queue_free()
	var b := ScheduleSources.bridge()
	var ps := _people()
	if b == null or ps.is_empty():
		_balance_box.add_child(EmptyState.make("users", "No simulated people here yet."))
		return
	var r := ScheduleSources.routine_of(_hab)
	var labour: NpcLabourLog = b.labour_for(_hab)
	var ph: Dictionary = b.rota_for(_hab).get("planned_h", {})
	var today := ScheduledEvents.day_of(ScheduleSources.now_h())
	var planned: Array = []
	var worked: Array = []
	var sleep_tot := 0.0
	var free_tot := 0.0
	var data: Array = []
	for p in ps:
		var pid := str(p["id"])
		var pl := float(ph.get(pid, 0.0))
		var wk := labour.hours_between(pid, today - 7, today - 1) if labour != null else 0.0
		planned.append(pl)
		worked.append(wk)
		var segs := ScheduledEvents.person_day(r, pid, float(p["offset_h"]), today)
		var by := ScheduledEvents.hours_by_kind(segs)
		sleep_tot += float(by.get("sleep", 0.0))
		free_tot += float(by.get("free", 0.0)) + float(by.get("social", 0.0)) + float(by.get("enrichment", 0.0))
		data.append([str(p["name"]), pl, wk])
	var n := float(ps.size())
	var tiles := StatTiles.make(4)
	_balance_box.add_child(tiles)
	tiles.set_tiles([
		{"caption": "Planned work per person", "value": UiText.duration(_sum(planned) / n),
			"tip": "The rota's hours for the next 7 days"},
		{"caption": "Spread (Gini)", "value": "%.2f" % _gini(planned),
			"tip": "0 = everyone the same hours, 1 = one person does it all",
			"level": "ok" if _gini(planned) <= 0.1 else "warn"},
		{"caption": "Worked last week", "value": UiText.duration(_sum(worked) / n),
			"tip": "Per person, from the labour log"},
		{"caption": "Sleep / free a day", "value": "%s / %s" % [UiText.duration(sleep_tot / n), UiText.duration(free_tot / n)],
			"tip": "From their routine days (free = free, hanging out, venues)"},
	])
	data.sort_custom(func(a, c) -> bool: return float(a[1]) > float(c[1]))
	var mx := 0.1
	for d in data:
		mx = maxf(mx, maxf(float(d[1]), float(d[2])))
	for d in data:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var nl := Label.new()
		nl.text = str(d[0])
		nl.custom_minimum_size.x = 140
		row.add_child(nl)
		var bar := ProgressBar.new()
		bar.max_value = mx
		bar.value = float(d[1])
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(320, 14)
		bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		UITheme.style_progress(bar)
		row.add_child(bar)
		var vl := Label.new()
		vl.text = "planned %s · worked %s" % [UiText.duration(float(d[1])), UiText.duration(float(d[2]))]
		vl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
		row.add_child(vl)
		_balance_box.add_child(row)
	_add_time_use(b, ps)


## How they really spent their days (NpcTimeUse, measured as the sim runs):
## the camp's average day against the American Time Use Survey, each
## person's day, and the work per person per week against the rota's.
func _add_time_use(b: Object, ps: Array) -> void:
	_balance_box.add_child(SectionHeader.make("How they spend their days", "",
		"measured as the clock runs, last 7 days"))
	var tu: Dictionary = b.call("time_use_summary", 7, _hab)
	if int(tu.get("people", 0)) == 0 or float(tu.get("recorded_h", 0.0)) < 1.0:
		_balance_box.add_child(EmptyState.row("clock", "Nothing measured yet: run the clock for a while."))
		return
	var names := {}
	for p in ps:
		names[str(p["id"])] = str(p["name"])
	for p in tu["per_person"]:
		p["name"] = names.get(str(p["id"]), str(p["id"]))
	(tu["per_person"] as Array).sort_custom(func(a, c) -> bool: return str(a["name"]) < str(c["name"]))
	var v := str(tu["verdict"])
	var tiles := StatTiles.make(4)
	tiles.name = "time_use_tiles"
	_balance_box.add_child(tiles)
	tiles.set_tiles([
		{"caption": "Work per person a week", "value": UiText.duration(float(tu["work_h_week"])),
			"tip": "Measured. Up to %s a week (the ATUS adult's paid work and housework) is sustainable, past %s overloaded." % [
				UiText.duration(NpcTimeUse.SUSTAINABLE_H_WEEK), UiText.duration(NpcTimeUse.OVERLOADED_H_WEEK)],
			"level": "ok" if v == "sustainable" else ("warn" if v == "heavy" else "crit")},
		{"caption": "The rota plans", "value": UiText.duration(float(tu.get("planned_h_week", 0.0))),
			"tip": "Per person per week: the recurring work the rota crews (meals, duties, repeating chores)"},
		{"caption": "Leisure a day", "value": UiText.duration(float(tu["leisure_h_day"])),
			"tip": "Hanging out, venues and gatherings (ATUS 2025: %s of leisure and sports)" % UiText.duration(5.16)},
		{"caption": "Measured", "value": ("part of a day · %s" if bool(tu.get("partial", false)) else UiText.count(int(tu["days"]), "day") + " · %s") % UiText.count(int(tu["people"]), "person", "people"),
			"tip": "Time is counted while the clock runs forward; a jump or a scrub back is not counted. Whole days only once one is complete; a part day leans on its hours (a morning has no night's sleep in it)",
			"level": "warn" if bool(tu.get("partial", false)) else ""},
	])
	var g := TimeUseBars.new()
	g.name = "time_use_groups"
	g.mode = "groups"
	_balance_box.add_child(g)
	g.set_summary(tu)
	var src := Label.new()
	src.text = "Ticks: %s. A reference, not a target." % NpcTimeUse.ATUS_SOURCE
	src.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	src.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_balance_box.add_child(src)
	var pp := TimeUseBars.new()
	pp.name = "time_use_people"
	pp.mode = "people"
	pp.show_head = false
	_balance_box.add_child(pp)
	pp.set_summary(tu)


static func _sum(xs: Array) -> float:
	var t := 0.0
	for x in xs:
		t += float(x)
	return t


static func _gini(xs: Array) -> float:
	var n := xs.size()
	if n < 2:
		return 0.0
	var s := xs.duplicate()
	s.sort()
	var tot := _sum(s)
	if tot <= 1e-9:
		return 0.0
	var acc := 0.0
	for i in n:
		acc += float(2 * (i + 1) - n - 1) * float(s[i])
	return acc / (float(n) * tot)


# --- footer + doorways ------------------------------------------------------------------------

func _export() -> void:
	var h0 := float(ScheduledEvents.day_of(ScheduleSources.now_h())) * 24.0
	var res := ScheduleSources.export_ics(h0, h0 + 7.0 * 24.0)
	var files: Array = res.get("files", [])
	_status.text = "Wrote %s (%s) to %s." % [UiText.count(files.size(), "calendar"),
		UiText.count(int(res.get("events", 0)), "event"), ProjectSettings.globalize_path(str(res.get("dir", "")))]
	_status.tooltip_text = _status.text
	set_meta("last_export", res)


func _open_folder() -> void:
	var res: Dictionary = get_meta("last_export", {}) if has_meta("last_export") else {}
	var dir := str(res.get("dir", ScheduleSources.EXPORT_DIR))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	OS.shell_open(ProjectSettings.globalize_path(dir))


func _open_routines() -> void:
	var g := ServiceLocator.graph()
	if g != null and g.has_method("open_npc_routines"):
		g.call("open_npc_routines", _hab)
		_frame.close()
	else:
		_status.text = "Open the habitat's inspector on the graph → Routines & chores."
