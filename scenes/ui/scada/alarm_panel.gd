extends Node
## The alarm window (plans/SCADA_PROCESS_PLAN.md, Phase 5): what is in alarm
## now, the rules, and the journal. Opened by SystemGraphView.open_alarm_panel
## (the Process lens's alarm bar and Alarms button, the HUD chip).
##
##   open(view, hub, tab)      tab "active" | "rules" | "journal"
##   show_tab(tab), tab(), is_open(), close()
##   button(name), field(name)   for checks: ack_<id>, shelve_<id>, ack_all,
##                               add_rule, suggest, del_<id>, tab_<tab>,
##                               r_<id>_<key> (name, tag, op, limit, deadband,
##                               delay_s, priority, enabled)

const TABS := [["active", "Now"], ["rules", "Rules"], ["journal", "Journal"]]
const PRI_COLORS := {"high": Color(0.94, 0.33, 0.31), "medium": Color(0.98, 0.70, 0.22), "low": Color(0.35, 0.78, 0.98)}

var _view: Node = null
var _hub: Node = null
var _frame: ModalFrame = null
var _tab := "active"
var _tab_btns: Dictionary = {}
var _box: VBoxContainer = null
var _sig := ""
var _acc := 0.0


func open(view: Node, hub: Node, tab: String = "") -> void:
	_view = view
	_hub = hub
	_frame = ModalFrame.create("Alarms", "Limits on any tag. An alarm flashes until someone acknowledges it, and stays listed while its condition holds.",
		Vector2(1080, 720), "scada_alarm_panel")
	_frame.content_max_w = 0.0
	add_child(_frame)
	_frame.closed.connect(queue_free)
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 6)
	_frame.body.add_child(bar)
	for t in TABS:
		var b := Button.new()
		b.name = "tab_%s" % str(t[0])
		b.text = str(t[1])
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		UITheme.style_button(b)
		var which := str(t[0])
		b.pressed.connect(func() -> void: show_tab(which))
		bar.add_child(b)
		_tab_btns[which] = b
	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", 6)
	_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_frame.body.add_child(_box)
	_frame.add_button("Close", ModalFrame.SECONDARY, _frame.close)
	_frame.open()
	if _hub != null and _hub.get("modal_layer") != null:
		_frame.layer = int(_hub.get("modal_layer"))
	var start := tab
	if start.is_empty():
		start = "active" if not (_hub.call("alarm_rules") as Array).is_empty() else "rules"
	show_tab(start)


func close() -> void:
	if _frame != null and is_instance_valid(_frame):
		_frame.close()


func is_open() -> bool:
	return _frame != null and is_instance_valid(_frame) and _frame.visible


func tab() -> String:
	return _tab


func button(n: String) -> Button:
	return (_frame.find_child(n, true, false) as Button) if _frame != null else null


func field(n: String) -> Control:
	return (_frame.find_child(n, true, false) as Control) if _frame != null else null


func show_tab(which: String) -> void:
	_tab = which if which in ["active", "rules", "journal"] else "active"
	for k in _tab_btns:
		(_tab_btns[k] as Button).set_pressed_no_signal(str(k) == _tab)
	_sig = ""
	_rebuild()


func _process(delta: float) -> void:
	if not is_open():
		return
	_acc += delta
	if _acc < 0.4:
		return
	_acc = 0.0
	# Lists follow the alarms; the rules form is only rebuilt by its own edits
	# (a rebuild under the pointer would take a field out of the player's hand).
	if _tab != "rules":
		_rebuild()


func _clock(h: float) -> String:
	if is_nan(h):
		return ""
	var hod := fposmod(h, 24.0)
	return "%02d:%02d" % [int(hod), int(fposmod(hod * 60.0, 60.0))]


func _clear() -> void:
	for c in _box.get_children():
		_box.remove_child(c)
		c.queue_free()


func _rebuild() -> void:
	if _hub == null:
		return
	var sig := ""
	match _tab:
		"active":
			sig = str(_hub.call("alarm_active"))
		"journal":
			sig = str((_hub.call("alarm_journal") as Array).size())
		"rules":
			sig = "rules"
	if sig == _sig and _tab != "rules":
		return
	_sig = sig
	_clear()
	match _tab:
		"active":
			_build_active()
		"rules":
			_build_rules()
		"journal":
			_build_journal()


func _btn(n: String, text: String, tip: String, cb: Callable) -> Button:
	var b := Button.new()
	b.name = n
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(b)
	b.pressed.connect(cb)
	return b


func _dot(priority: String) -> ColorRect:
	var d := ColorRect.new()
	d.color = PRI_COLORS.get(priority, UITheme.C_TEXT_M)
	d.custom_minimum_size = Vector2(10, 22)
	d.tooltip_text = "%s priority" % str(ScadaAlarms.PRIORITY_WORDS.get(priority, priority))
	d.mouse_filter = Control.MOUSE_FILTER_STOP
	return d


# ── now ─────────────────────────────────────────────────────────────────────

func _build_active() -> void:
	var list: Array = _hub.call("alarm_active")
	if (_hub.call("alarm_rules") as Array).is_empty():
		_box.add_child(EmptyState.make("bell", "No alarm rules yet.\nA rule watches one tag: a tank nearly full, a pump that tripped, a battery running low.",
			"Set up rules", func() -> void: show_tab("rules")))
		return
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	var sm: Dictionary = _hub.call("alarm_summary")
	var lbl := Label.new()
	lbl.name = "active_count"
	lbl.text = "Nothing in alarm." if list.is_empty() else "%s in alarm, %s to acknowledge." % [UiText.count(int(sm["active"]), "thing"), str(int(sm["unack"]))]
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(lbl)
	var aa := _btn("ack_all", "Acknowledge all", "Says you have seen them. They stay listed while their conditions hold.",
		func() -> void: _hub.call("alarm_command", "", "ack_all"))
	aa.disabled = int(sm["unack"]) == 0
	head.add_child(aa)
	_box.add_child(head)
	for a in list:
		var row := HBoxContainer.new()
		row.name = "row_%s" % str(a["id"])
		row.add_theme_constant_override("separation", 8)
		row.add_child(_dot(str(a["priority"])))
		var nm := Label.new()
		nm.text = str(a["name"])
		nm.custom_minimum_size.x = 260
		nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		nm.add_theme_font_override("font", UITheme.font("semibold"))
		row.add_child(nm)
		var tx := Label.new()
		tx.text = str(a["text"])
		tx.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tx.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		row.add_child(tx)
		var stw := Label.new()
		var state := str(a["state"])
		stw.text = {"unack": "New", "acked": "Seen", "rtn": "Cleared"}.get(state, state) + ("  since %s" % _clock(float(a["since_h"])) if not is_nan(float(a["since_h"])) else "")
		stw.add_theme_color_override("font_color", UITheme.C_WARN if state == "unack" else UITheme.C_TEXT_M)
		stw.custom_minimum_size.x = 150
		row.add_child(stw)
		var id := str(a["id"])
		var ack := _btn("ack_%s" % id, "Acknowledge", "", func() -> void: _hub.call("alarm_command", id, "ack"))
		ack.disabled = state == "acked"
		row.add_child(ack)
		row.add_child(_btn("shelve_%s" % id, "Shelve 1 h", "Puts this alarm aside for an hour of the site's clock: it raises nothing until then.",
			func() -> void: _hub.call("alarm_command", id, "shelve", 1.0)))
		_box.add_child(row)
	# Shelved ones, so they can be brought back.
	var st: Dictionary = _hub.call("alarm_status")
	for r in _hub.call("alarm_rules"):
		var rid := str(r["id"])
		if str((st.get(rid, {}) as Dictionary).get("state", "")) != "shelved":
			continue
		var row2 := HBoxContainer.new()
		row2.add_theme_constant_override("separation", 8)
		row2.add_child(_dot(str(r.get("priority", "medium"))))
		var l2 := Label.new()
		l2.text = "%s  ·  shelved" % str(r.get("name", rid))
		l2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l2.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		row2.add_child(l2)
		row2.add_child(_btn("unshelve_%s" % rid, "Bring back", "", func() -> void: _hub.call("alarm_command", rid, "unshelve")))
		_box.add_child(row2)


# ── rules ───────────────────────────────────────────────────────────────────

func _put(id: String, key: String, value: Variant, rebuild: bool = false) -> void:
	var all: Array = (_hub.call("alarm_rules") as Array).duplicate(true)
	for r in all:
		if str(r["id"]) == id:
			r[key] = value
	_hub.call("set_alarm_rules", all)
	if rebuild:
		_sig = ""
		_rebuild()


func _tag_text(tag: String) -> String:
	if tag.is_empty():
		return "Pick a tag…"
	var t: Dictionary = (_hub.call("book") as ScadaTags).tag(tag)
	return "%s · %s" % [str(t.get("group", "")), str(t.get("label", tag))] if not t.is_empty() else tag


func _build_rules() -> void:
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	head.add_child(_btn("add_rule", "Add a rule", "", func() -> void:
		var all: Array = (_hub.call("alarm_rules") as Array).duplicate(true)
		all.append(ScadaAlarms.make(str(_hub.call("new_alarm_id")), "New alarm", "", ">=", 90.0))
		_hub.call("set_alarm_rules", all)
		_sig = ""
		_rebuild()))
	head.add_child(_btn("suggest", "Suggest for this site", "A high and a low level on every store, a trip on every interlock, a low battery. Rules you already have are left alone.",
		func() -> void:
			_hub.call("suggest_alarms")
			_sig = ""
			_rebuild()))
	_box.add_child(head)
	var rules: Array = _hub.call("alarm_rules")
	if rules.is_empty():
		_box.add_child(EmptyState.row("bell", "No rules yet. Add one, or let the game suggest a set for what this site has."))
		return
	for r in rules:
		var id := str(r["id"])
		var card := PanelContainer.new()
		card.name = "rule_%s" % id
		card.add_theme_stylebox_override("panel", UITheme.card_style())
		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 4)
		card.add_child(v)
		var a := HBoxContainer.new()
		a.add_theme_constant_override("separation", 6)
		v.add_child(a)
		a.add_child(_dot(str(r.get("priority", "medium"))))
		var ne := LineEdit.new()
		ne.name = "r_%s_name" % id
		ne.text = str(r.get("name", ""))
		ne.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		ne.text_changed.connect(func(t: String) -> void: _put(id, "name", t))
		a.add_child(ne)
		var en := CheckBox.new()
		en.name = "r_%s_enabled" % id
		en.text = "On"
		en.button_pressed = bool(r.get("enabled", true))
		en.toggled.connect(func(on: bool) -> void: _put(id, "enabled", on))
		a.add_child(en)
		var del := IconButton.make("trash-2", "Delete this rule", func() -> void:
			var all: Array = (_hub.call("alarm_rules") as Array).filter(func(x: Dictionary) -> bool: return str(x["id"]) != id)
			_hub.call("set_alarm_rules", all)
			_sig = ""
			_rebuild())
		del.name = "del_%s" % id
		a.add_child(del)
		var b := HBoxContainer.new()
		b.add_theme_constant_override("separation", 6)
		v.add_child(b)
		var tb := Button.new()
		tb.name = "r_%s_tag" % id
		tb.text = _tag_text(str(r.get("tag", "")))
		tb.tooltip_text = str(r.get("tag", ""))
		tb.clip_text = true
		tb.custom_minimum_size.x = 300
		tb.alignment = HORIZONTAL_ALIGNMENT_LEFT
		tb.focus_mode = Control.FOCUS_NONE
		UITheme.style_button(tb)
		tb.pressed.connect(func() -> void:
			if _view != null and _view.has_method("open_tag_browser"):
				_view.call("open_tag_browser", {"title": "Pick the tag to watch",
					"pick": func(t: Dictionary) -> void: _put(id, "tag", str(t.get("id", "")), true)}))
		b.add_child(tb)
		var op := OptionButton.new()
		op.name = "r_%s_op" % id
		for o in ScadaAlarms.OPS:
			op.add_item(str(ScadaAlarms.OP_WORDS[o]))
			if o == str(r.get("op", ">=")):
				op.select(op.item_count - 1)
		op.item_selected.connect(func(i: int) -> void: _put(id, "op", str(ScadaAlarms.OPS[i]), true))
		b.add_child(op)
		var numeric := str(r.get("op", ">=")) in [">=", "<="]
		if numeric:
			b.add_child(_spin("r_%s_limit" % id, float(r.get("limit", 0.0)), -1e6, 1e6, 0.5, "", "", func(x: float) -> void: _put(id, "limit", x)))
			b.add_child(_spin("r_%s_deadband" % id, float(r.get("deadband", 0.0)), 0.0, 1e6, 0.5, "", "clears ",
				func(x: float) -> void: _put(id, "deadband", x), "How far back past the limit the reading must come before the alarm clears."))
		b.add_child(_spin("r_%s_delay_s" % id, float(r.get("delay_s", 0.0)), 0.0, 86400.0, 5.0, " s", "after ",
			func(x: float) -> void: _put(id, "delay_s", x), "How long the condition must hold before the alarm raises."))
		var pr := OptionButton.new()
		pr.name = "r_%s_priority" % id
		for p in ScadaAlarms.PRIORITIES:
			pr.add_item(str(ScadaAlarms.PRIORITY_WORDS[p]))
			if p == str(r.get("priority", "medium")):
				pr.select(pr.item_count - 1)
		pr.item_selected.connect(func(i: int) -> void: _put(id, "priority", str(ScadaAlarms.PRIORITIES[i]), true))
		pr.tooltip_text = "Priority"
		b.add_child(pr)
		_box.add_child(card)


func _spin(n: String, v: float, lo: float, hi: float, step: float, suffix: String, prefix: String, on: Callable, tip: String = "") -> SpinBox:
	var s := SpinBox.new()
	s.name = n
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = v
	s.suffix = suffix
	s.prefix = prefix
	s.tooltip_text = tip
	s.custom_minimum_size.x = 128
	s.value_changed.connect(on)
	return s


# ── journal ─────────────────────────────────────────────────────────────────

func _build_journal() -> void:
	var j: Array = _hub.call("alarm_journal")
	if j.is_empty():
		_box.add_child(EmptyState.row("list", "Nothing has happened yet. Every alarm raised, cleared, acknowledged or shelved is written here."))
		return
	var words := {"raised": "Raised", "cleared": "Cleared", "ack": "Acknowledged", "shelve": "Shelved", "unshelve": "Brought back"}
	for i in range(j.size() - 1, maxi(j.size() - 121, -1), -1):
		var e: Dictionary = j[i]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.add_child(_dot(str(e.get("priority", "medium"))))
		var t := Label.new()
		t.text = _clock(float(e.get("h", NAN)))
		t.custom_minimum_size.x = 56
		t.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		row.add_child(t)
		var w := Label.new()
		w.text = str(words.get(str(e.get("what", "")), str(e.get("what", ""))))
		w.custom_minimum_size.x = 120
		row.add_child(w)
		var n := Label.new()
		n.text = "%s  %s" % [str(e.get("name", "")), str(e.get("text", ""))]
		n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		n.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		row.add_child(n)
		_box.add_child(row)
