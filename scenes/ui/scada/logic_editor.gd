extends Node

## The control logic window (plans/SCADA_PROCESS_PLAN.md, Phase 4): the
## site's blocks (on / off bands, PID loops, interlocks, timers, counters,
## sequences) as a list with a plain-word form for the selected one.
##
##   open(view, hub, select_id)
## Left: the blocks (name, kind, live status) and "Add" from ready-made
## templates. Right: the selected block's form. Every edit is applied at
## once (`hub.set_logic_blocks`) and saved with the graph.
##
## Harness: `select(id)`, `add_template(which)`, `field(name)`,
## `button(name)`, `block_ids()`, `close()`.

const LABEL_W := 150.0

var _view: Node = null
var _hub: Node = null
var _frame: ModalFrame = null
var _list: VBoxContainer = null
var _form: VBoxContainer = null
var _status: Label = null
var _sel := ""
var _acc := 0.0
var _row_status: Dictionary = {}


func open(view: Node, hub: Node, select_id: String = "") -> void:
	_view = view
	_hub = hub
	_frame = ModalFrame.create("Control logic",
		"Blocks that read tags and switch things: they run on the site's clock, whether or not this window is open.",
		Vector2(1080, 720), "scada_logic_editor")
	_frame.content_max_w = 0.0
	add_child(_frame)
	_frame.closed.connect(queue_free)
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 16)
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_frame.body.add_child(cols)
	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 340
	left.add_theme_constant_override("separation", 6)
	cols.add_child(left)
	left.add_child(SectionHeader.make("Blocks"))
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 4)
	left.add_child(_list)
	left.add_child(SectionHeader.make("Add"))
	for row in ScadaLogic.TEMPLATES:
		var b := Button.new()
		b.name = "add_%s" % str(row[0])
		b.text = str(row[1])
		b.tooltip_text = str(row[2])
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.focus_mode = Control.FOCUS_NONE
		UITheme.style_button(b)
		var which := str(row[0])
		b.pressed.connect(func() -> void: add_template(which))
		left.add_child(b)
	_form = VBoxContainer.new()
	_form.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_form.add_theme_constant_override("separation", 6)
	cols.add_child(_form)
	if _hub != null and _hub.has_method("export_logic"):
		var ex: Button = _frame.add_button("Export for Home Assistant", ModalFrame.SECONDARY, _export)
		if ex != null:
			ex.name = "export_btn"
			ex.tooltip_text = "Writes every block as Home Assistant YAML (a PID as an ESPHome snippet), copies it, and saves it under the game's user folder."
	_frame.add_button("Close", ModalFrame.SECONDARY, _frame.close)
	_frame.open()
	# Over a designer that is itself above the usual modal layer.
	if _hub != null and _hub.get("modal_layer") != null:
		_frame.layer = int(_hub.get("modal_layer"))
	var ids := block_ids()
	_sel = select_id if select_id in ids else (str(ids[0]) if not ids.is_empty() else "")
	_rebuild()


func close() -> void:
	if _frame != null:
		_frame.close()


func is_open() -> bool:
	return _frame != null and is_instance_valid(_frame) and _frame.visible


func block_ids() -> Array:
	var out: Array = []
	for b in _blocks():
		out.append(str(b["id"]))
	return out


func selected() -> String:
	return _sel


func select(id: String) -> void:
	_sel = id
	_rebuild()


func field(n: String) -> Control:
	return _form.find_child(n, true, false) as Control if _form != null else null


func button(n: String) -> Button:
	var c: Node = _frame.find_child(n, true, false) if _frame != null else null
	return c as Button


func _blocks() -> Array:
	return (_hub.call("logic_blocks") as Array).duplicate(true) if _hub != null else []


func _block() -> Dictionary:
	for b in _blocks():
		if str(b["id"]) == _sel:
			return b
	return {}


## Write one block back (by id) and keep the form as it is.
func _put(b: Dictionary, rebuild: bool = false) -> void:
	var all := _blocks()
	for i in all.size():
		if str(all[i]["id"]) == str(b["id"]):
			all[i] = b
	_hub.call("set_logic_blocks", all)
	if rebuild:
		_rebuild()
	else:
		_refresh_list_names()


func add_template(which: String) -> String:
	var id := str(_hub.call("new_logic_id"))
	var all := _blocks()
	all.append(ScadaLogic.template(which, id))
	_hub.call("set_logic_blocks", all)
	_sel = id
	_rebuild()
	return id


func _delete() -> void:
	var all := _blocks().filter(func(b: Dictionary) -> bool: return str(b["id"]) != _sel)
	_hub.call("set_logic_blocks", all)
	_sel = str(all[0]["id"]) if not all.is_empty() else ""
	_rebuild()


func _process(delta: float) -> void:
	if not is_open():
		return
	_acc += delta
	if _acc < 0.25:
		return
	_acc = 0.0
	_refresh_status()


func _refresh_status() -> void:
	var st: Dictionary = _hub.call("logic_status") if _hub != null else {}
	for id in _row_status:
		var lbl: Label = _row_status[id]
		if not is_instance_valid(lbl):
			continue
		var s: Dictionary = st.get(id, {}) as Dictionary
		lbl.text = str(s.get("text", "…"))
		lbl.add_theme_color_override("font_color", UITheme.C_WARN if str(s.get("level", "")) == "warn"
			else (UITheme.C_TEXT_M if str(s.get("level", "")) == "off" else UITheme.C_OK))
	if _status != null and is_instance_valid(_status):
		var s2: Dictionary = st.get(_sel, {}) as Dictionary
		var notes: Dictionary = _hub.call("logic_notes")
		var extra := ""
		for tag in ScadaLogic.tags_used(_block())["writes"]:
			if notes.has(tag):
				extra = "  ·  cannot write %s: %s" % [_tag_label(str(tag)), str(notes[tag])]
		_status.text = str(s2.get("text", "")) + extra


func _refresh_list_names() -> void:
	for b in _blocks():
		var btn: Button = _list.find_child("block_%s" % str(b["id"]), true, false)
		if btn != null:
			btn.text = str(b.get("name", b["id"]))


func _rebuild() -> void:
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
	_row_status = {}
	var all := _blocks()
	if all.is_empty():
		_list.add_child(EmptyState.row("workflow", "No logic yet. Pick one under Add."))
	for b in all:
		var id := str(b["id"])
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 0)
		var btn := Button.new()
		btn.name = "block_%s" % id
		btn.text = str(b.get("name", id))
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.toggle_mode = true
		btn.button_pressed = id == _sel
		btn.focus_mode = Control.FOCUS_NONE
		btn.clip_text = true
		UITheme.style_button(btn)
		btn.pressed.connect(func() -> void: select(id))
		box.add_child(btn)
		var st := Label.new()
		st.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		st.text = str(ScadaLogic.KIND_LABELS.get(str(b["kind"]), ""))
		st.clip_text = true
		box.add_child(st)
		_row_status[id] = st
		_list.add_child(box)
	for c in _form.get_children():
		_form.remove_child(c)
		c.queue_free()
	_status = null
	var b := _block()
	if b.is_empty():
		_form.add_child(EmptyState.make("workflow", "Pick a block on the left, or add one.\nA block reads a tag (a level, a temperature) and switches something (a pump, a valve).", "", Callable()))
		return
	_build_form(b)
	_refresh_status()


# ── form pieces ─────────────────────────────────────────────────────────────

func _row(label: String, ctl: Control, tip: String = "") -> void:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	var l := Label.new()
	l.text = label
	l.custom_minimum_size.x = LABEL_W
	l.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	l.tooltip_text = tip
	l.mouse_filter = Control.MOUSE_FILTER_PASS if not tip.is_empty() else Control.MOUSE_FILTER_IGNORE
	h.add_child(l)
	h.add_child(ctl)
	_form.add_child(h)


func _spin(n: String, v: float, lo: float, hi: float, step: float, suffix: String, on: Callable) -> SpinBox:
	var s := SpinBox.new()
	s.name = n
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.allow_greater = true
	s.allow_lesser = lo < 0.0
	s.suffix = suffix
	s.custom_minimum_size.x = 150
	s.set_value_no_signal(v)
	s.value_changed.connect(on)
	return s


func _option(n: String, items: Array, current: String, on: Callable) -> OptionButton:
	var o := OptionButton.new()
	o.name = n
	o.fit_to_longest_item = false
	o.custom_minimum_size.x = 200
	for i in items.size():
		o.add_item(str(items[i][1]))
		if str(items[i][0]) == current:
			o.select(i)
	o.item_selected.connect(func(i: int) -> void: on.call(str(items[i][0])))
	return o


func _tag_label(tag: String) -> String:
	if tag.is_empty():
		return "Pick…"
	var t: Dictionary = (_hub.call("book") as ScadaTags).tag(tag) if _hub != null else {}
	if t.is_empty():
		return tag
	return "%s · %s" % [str(t.get("group", "")), str(t.get("label", ""))]


## A button showing a tag; a click opens the tag list to pick another.
func _tag_btn(n: String, tag: String, writable: bool, on: Callable) -> Button:
	var b := Button.new()
	b.name = n
	b.text = _tag_label(tag)
	b.tooltip_text = tag if not tag.is_empty() else ("Pick what to switch" if writable else "Pick a reading")
	b.clip_text = true
	b.custom_minimum_size.x = 300
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(b)
	b.set_meta("tag", tag)
	b.pressed.connect(func() -> void:
		_view.call("open_tag_browser", {"pick": func(t: Dictionary) -> void: on.call(str(t.get("id", ""))),
			"writable": writable, "title": "Pick what to switch" if writable else "Pick a reading"}))
	return b


func _cmd(n: String, text: String, what: String, value: float = 0.0) -> Button:
	var b := Button.new()
	b.name = "cmd_%s" % n
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(b)
	b.pressed.connect(func() -> void:
		_hub.call("logic_command", _sel, what, value)
		_refresh_status(), CONNECT_DEFERRED)
	return b


func _put_key(key: String, value: Variant, rebuild: bool = false) -> void:
	var b := _block()
	if b.is_empty():
		return
	b[key] = value
	_put(b, rebuild)


func _build_form(b: Dictionary) -> void:
	var kind := str(b["kind"])
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	var name_edit := LineEdit.new()
	name_edit.name = "f_name"
	name_edit.text = str(b.get("name", ""))
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_edit.text_changed.connect(func(t: String) -> void: _put_key("name", t))
	head.add_child(name_edit)
	var en := CheckBox.new()
	en.name = "f_enabled"
	en.text = "Running"
	en.button_pressed = bool(b.get("enabled", true))
	en.toggled.connect(func(on: bool) -> void: _put_key("enabled", on))
	head.add_child(en)
	var del := IconButton.make("trash-2", "Delete this block", _delete)
	del.name = "delete_block"
	head.add_child(del)
	_form.add_child(head)
	_status = Label.new()
	_status.name = "status"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_color_override("font_color", UITheme.C_TEXT)
	_form.add_child(_status)
	_form.add_child(SectionHeader.make(str(ScadaLogic.KIND_LABELS.get(kind, kind))))
	match kind:
		"band":
			_row("Reads", _tag_btn("f_pv", str(b.get("pv", "")), false, func(t: String) -> void: _put_key("pv", t, true)))
			_row("Switches", _tag_btn("f_out", str(b.get("out", "")), true, func(t: String) -> void: _put_key("out", t, true)))
			_row("It is there to", _option("f_direction", [["fill", "Raise the reading (fill, heat)"], ["drain", "Lower the reading (drain, cool)"]],
				str(b.get("direction", "fill")), func(v: String) -> void: _put_key("direction", v)))
			_row("Low mark", _spin("f_low", float(b.get("low", 0.0)), -1e6, 1e6, 0.5, "", func(v: float) -> void: _put_key("low", v)),
				"Raising: it switches ON at or below this. Lowering: OFF.")
			_row("High mark", _spin("f_high", float(b.get("high", 0.0)), -1e6, 1e6, 0.5, "", func(v: float) -> void: _put_key("high", v)),
				"Raising: it switches OFF at or above this. Lowering: ON.")
		"pid":
			_row("Reads", _tag_btn("f_pv", str(b.get("pv", "")), false, func(t: String) -> void: _put_key("pv", t, true)))
			_row("Drives", _tag_btn("f_out", str(b.get("out", "")), true, func(t: String) -> void: _put_key("out", t, true)),
				"A control valve's opening (0 to 100 %).")
			_row("Setpoint", _spin("f_sp", float(b.get("sp", 0.0)), -1e6, 1e6, 0.5, "", func(v: float) -> void: _put_key("sp", v)))
			_row("Gain", _spin("f_kp", float(b.get("kp", 1.0)), 0.0, 1000.0, 0.1, " % per unit", func(v: float) -> void: _put_key("kp", v)),
				"How hard it pushes: % of output for each unit the reading is off.")
			_row("Integral time", _spin("f_ti_min", float(b.get("ti_min", 0.0)), 0.0, 100000.0, 0.5, " min", func(v: float) -> void: _put_key("ti_min", v)),
				"How long it takes to repeat that push while the reading stays off. 0 = no integral.")
			_row("Derivative time", _spin("f_td_min", float(b.get("td_min", 0.0)), 0.0, 10000.0, 0.1, " min", func(v: float) -> void: _put_key("td_min", v)),
				"Braking against a fast-moving reading. 0 = none (the usual choice for levels).")
			var rev := CheckBox.new()
			rev.name = "f_reverse"
			rev.text = "More output LOWERS the reading (a drain valve, a cooler)"
			rev.button_pressed = bool(b.get("reverse", false))
			rev.toggled.connect(func(on: bool) -> void: _put_key("reverse", on))
			_form.add_child(rev)
			var modes := HBoxContainer.new()
			modes.add_theme_constant_override("separation", 6)
			modes.add_child(_cmd("auto", "Auto", "auto"))
			modes.add_child(_cmd("manual", "Manual", "manual"))
			modes.add_child(_spin("f_manual_out", float(b.get("manual_out", 0.0)), 0.0, 100.0, 1.0, " %",
				func(v: float) -> void: _hub.call("logic_command", _sel, "out", v)))
			_row("Mode", modes, "In manual the output is what you set here; back in auto it carries on from there.")
			if _hub != null and _hub.has_method("tune_block"):
				var tb := Button.new()
				tb.name = "tune_btn"
				tb.text = "Suggest gains from a step test"
				tb.tooltip_text = "Tries a step of the output on a COPY of the graph, watches the reading, and works out gains (SIMC rules). An estimate: nothing in your world moves."
				tb.focus_mode = Control.FOCUS_NONE
				UITheme.style_button(tb)
				tb.pressed.connect(_tune)
				_row("Tuning", tb)
				_tune_box = VBoxContainer.new()
				_tune_box.name = "tune_box"
				_form.add_child(_tune_box)
		"interlock":
			var conds: Array = b.get("when", []) as Array
			for i in conds.size():
				var c: Dictionary = conds[i]
				var h := HBoxContainer.new()
				h.add_theme_constant_override("separation", 6)
				var idx := i
				h.add_child(_tag_btn("f_when_%d_tag" % i, str(c.get("tag", "")), false, func(t: String) -> void: _set_cond(idx, "tag", t, true)))
				var ops: Array = []
				for o in ScadaLogic.OPS:
					ops.append([o, o])
				var ob := _option("f_when_%d_op" % i, ops, str(c.get("op", ">")), func(v: String) -> void: _set_cond(idx, "op", v))
				ob.custom_minimum_size.x = 70
				h.add_child(ob)
				h.add_child(_spin("f_when_%d_value" % i, float(c.get("value", 0.0)), -1e6, 1e6, 0.5, "", func(v: float) -> void: _set_cond(idx, "value", v)))
				if conds.size() > 1:
					h.add_child(IconButton.make("x", "Remove this condition", func() -> void: _remove_cond(idx)))
				_row("While" if i == 0 else "", h)
			var add := Button.new()
			add.name = "add_condition"
			add.text = "Add a condition"
			add.focus_mode = Control.FOCUS_NONE
			UITheme.style_button(add)
			add.pressed.connect(_add_cond)
			_row("", add)
			if conds.size() > 1:
				_row("Trips when", _option("f_match", [["any", "Any one of them holds"], ["all", "All of them hold"]],
					str(b.get("match", "any")), func(v: String) -> void: _put_key("match", v)))
			_row("Forces", _tag_btn("f_out", str(b.get("out", "")), true, func(t: String) -> void: _put_key("out", t, true)))
			_row("To", _option("f_safe", [["0", "Off / closed"], ["1", "On / open"]], "1" if float(b.get("safe", 0.0)) >= 0.5 else "0",
				func(v: String) -> void: _put_key("safe", float(v))))
			var latch := CheckBox.new()
			latch.name = "f_latch"
			latch.text = "Stay tripped until someone resets it"
			latch.button_pressed = bool(b.get("latch", false))
			latch.toggled.connect(func(on: bool) -> void: _put_key("latch", on))
			_form.add_child(latch)
			_row("", _cmd("reset", "Reset", "reset"))
		"duty":
			var dconds: Array = b.get("when", []) as Array
			for i in dconds.size():
				var dc: Dictionary = dconds[i]
				var dh := HBoxContainer.new()
				dh.add_theme_constant_override("separation", 6)
				var di := i
				dh.add_child(_tag_btn("f_when_%d_tag" % i, str(dc.get("tag", "")), false, func(t: String) -> void: _set_cond(di, "tag", t, true)))
				dh.add_child(_ops("f_when_%d_op" % i, str(dc.get("op", "<")), func(v: String) -> void: _set_cond(di, "op", v)))
				dh.add_child(_spin("f_when_%d_value" % i, float(dc.get("value", 0.0)), -1e6, 1e6, 0.5, "", func(v: float) -> void: _set_cond(di, "value", v)))
				_row("Run while" if i == 0 else "", dh)
			var outs: Array = (b.get("outs", ["", ""]) as Array).duplicate()
			while outs.size() < 2:
				outs.append("")
			_row("Machine A", _tag_btn("f_out_a", str(outs[0]), true, func(t: String) -> void:
				outs[0] = t
				_put_key("outs", outs, true)))
			_row("Machine B", _tag_btn("f_out_b", str(outs[1]), true, func(t: String) -> void:
				outs[1] = t
				_put_key("outs", outs, true)))
			_row("Take turns every", _spin("f_swap_h", float(b.get("swap_h", 24.0)), 0.0, 100000.0, 1.0, " h of running",
				func(v: float) -> void: _put_key("swap_h", v)), "The lead changes at the next start once it has run this long.")
			var asst: Dictionary = (b.get("assist", {}) as Dictionary).duplicate()
			var ah := HBoxContainer.new()
			ah.add_theme_constant_override("separation", 6)
			ah.add_child(_tag_btn("f_assist_tag", str(asst.get("tag", "")), false, func(t: String) -> void:
				asst["tag"] = t
				_put_key("assist", asst, true)))
			ah.add_child(_ops("f_assist_op", str(asst.get("op", "<")), func(v: String) -> void:
				asst["op"] = v
				_put_key("assist", asst)))
			ah.add_child(_spin("f_assist_value", float(asst.get("value", 0.0)), -1e6, 1e6, 0.5, "", func(v: float) -> void:
				asst["value"] = v
				_put_key("assist", asst)))
			_row("Both run while", ah, "Leave the tag empty for no help from the standby.")
			_row("", _cmd("swap", "Swap the lead now", "swap"))
		"timer":
			_row("Switches", _tag_btn("f_out", str(b.get("out", "")), true, func(t: String) -> void: _put_key("out", t, true)))
			_row("On for", _spin("f_on_min", float(b.get("on_min", 0.0)), 0.0, 100000.0, 1.0, " min", func(v: float) -> void: _put_key("on_min", v)))
			_row("Then off for", _spin("f_off_min", float(b.get("off_min", 0.0)), 0.0, 100000.0, 1.0, " min", func(v: float) -> void: _put_key("off_min", v)))
			_row("Starting", _spin("f_offset_min", float(b.get("offset_min", 0.0)), 0.0, 100000.0, 1.0, " min past", func(v: float) -> void: _put_key("offset_min", v)),
				"Minutes after midnight (or after the hour) the cycle starts on.")
		"counter":
			_row("Counts each time", _tag_btn("f_pv", str(b.get("pv", "")), false, func(t: String) -> void: _put_key("pv", t, true)))
			var ops2: Array = []
			for o in ScadaLogic.OPS:
				ops2.append([o, o])
			_row("becomes", _option("f_op", ops2, str(b.get("op", ">")), func(v: String) -> void: _put_key("op", v)))
			_row("", _spin("f_value", float(b.get("value", 0.5)), -1e6, 1e6, 0.5, "", func(v: float) -> void: _put_key("value", v)))
			_row("", _cmd("reset", "Back to zero", "reset"))
		"sequence":
			var run := HBoxContainer.new()
			run.add_theme_constant_override("separation", 6)
			run.add_child(_cmd("start", "Start", "start"))
			run.add_child(_cmd("hold", "Hold", "hold"))
			run.add_child(_cmd("resume", "Resume", "resume"))
			run.add_child(_cmd("abort", "Abort", "abort"))
			_row("Run it", run)
			var rep := CheckBox.new()
			rep.name = "f_repeat"
			rep.text = "Start again after the last step"
			rep.button_pressed = bool(b.get("repeat", false))
			rep.toggled.connect(func(on: bool) -> void: _put_key("repeat", on))
			_form.add_child(rep)
			var steps: Array = b.get("steps", []) as Array
			for i in steps.size():
				_build_step(i, steps[i])
			var add_s := Button.new()
			add_s.name = "add_step"
			add_s.text = "Add a step"
			add_s.focus_mode = Control.FOCUS_NONE
			UITheme.style_button(add_s)
			add_s.pressed.connect(_add_step)
			_form.add_child(add_s)


func _ops(n: String, current: String, on: Callable) -> OptionButton:
	var ops: Array = []
	for o in ScadaLogic.OPS:
		ops.append([o, o])
	var ob := _option(n, ops, current, on)
	ob.custom_minimum_size.x = 70
	return ob


var _tune_box: VBoxContainer = null
var _last_tune: Dictionary = {}
var _last_export: Dictionary = {}


func last_tune() -> Dictionary:
	return _last_tune


func last_export() -> Dictionary:
	return _last_export


func _tune() -> void:
	_last_tune = _hub.call("tune_block", _sel)
	if _tune_box == null or not is_instance_valid(_tune_box):
		return
	for c in _tune_box.get_children():
		_tune_box.remove_child(c)
		c.queue_free()
	var lbl := Label.new()
	lbl.name = "tune_text"
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM if "FONT_SM" in UITheme else 13)
	_tune_box.add_child(lbl)
	if not bool(_last_tune.get("ok", false)):
		lbl.text = str(_last_tune.get("why", "The step test gave nothing to read."))
		lbl.add_theme_color_override("font_color", UITheme.C_WARN)
		return
	var g: Dictionary = _last_tune["gains"]
	lbl.text = I18n.f("{text}\nSuggested (an estimate): gain {kp} % per unit, integral time {ti_min} min{reverse}.", {
		"text": str(g.get("text", "")),
		"kp": str(g["kp"]),
		"ti_min": str(g["ti_min"]),
		"reverse": ", more output LOWERS the reading" if bool(g.get("reverse", false)) else "",
	})
	var use := Button.new()
	use.name = "tune_use"
	use.text = "Use these gains"
	use.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(use)
	use.pressed.connect(func() -> void:
		var b := _block()
		b.merge({"kp": float(g["kp"]), "ti_min": float(g["ti_min"]), "td_min": 0.0, "reverse": bool(g.get("reverse", false))}, true)
		_put(b, true))
	_tune_box.add_child(use)


func _export() -> void:
	_last_export = _hub.call("export_logic")
	DisplayServer.clipboard_set(str(_last_export.get("yaml", "")))
	if _status != null and is_instance_valid(_status):
		_status.text = I18n.f("Copied {automations} automation(s) and {scripts} script(s) as YAML. Saved to {path}", {
			"automations": "%d" % (int(_last_export.get("automations", 0))),
			"scripts": "%d" % (int(_last_export.get("scripts", 0))),
			"path": str(_last_export.get("path", "the user folder")),
		})


func _set_cond(i: int, key: String, value: Variant, rebuild: bool = false) -> void:
	var b := _block()
	var conds: Array = b.get("when", []) as Array
	if i < conds.size():
		(conds[i] as Dictionary)[key] = value
		_put(b, rebuild)


func _add_cond() -> void:
	var b := _block()
	(b["when"] as Array).append({"tag": "", "op": ">", "value": 0.0})
	_put(b, true)


func _remove_cond(i: int) -> void:
	var b := _block()
	(b["when"] as Array).remove_at(i)
	_put(b, true)


func _step_edit(i: int, fn: Callable, rebuild: bool = false) -> void:
	var b := _block()
	var steps: Array = b.get("steps", []) as Array
	if i < steps.size():
		fn.call(steps[i] as Dictionary)
		_put(b, rebuild)


func _add_step() -> void:
	var b := _block()
	(b["steps"] as Array).append({"name": "Step %d" % ((b["steps"] as Array).size() + 1), "set": [{"tag": "", "value": 1.0}],
		"until": {}, "min_s": 60.0, "timeout_s": 0.0})
	_put(b, true)


func _build_step(i: int, s: Dictionary) -> void:
	_form.add_child(SectionHeader.make("Step %d" % (i + 1)))
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	var nm := LineEdit.new()
	nm.name = "f_step_%d_name" % i
	nm.text = str(s.get("name", ""))
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nm.text_changed.connect(func(t: String) -> void: _step_edit(i, func(d: Dictionary) -> void: d["name"] = t))
	head.add_child(nm)
	head.add_child(IconButton.make("trash-2", "Remove this step", func() -> void:
		var b := _block()
		(b["steps"] as Array).remove_at(i)
		_put(b, true)))
	_form.add_child(head)
	var acts: Array = s.get("set", []) as Array
	for k in acts.size():
		var a: Dictionary = acts[k]
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 6)
		var kk := k
		h.add_child(_tag_btn("f_step_%d_set_%d_tag" % [i, k], str(a.get("tag", "")), true, func(t: String) -> void:
			_step_edit(i, func(d: Dictionary) -> void: ((d["set"] as Array)[kk] as Dictionary)["tag"] = t, true)))
		h.add_child(_spin("f_step_%d_set_%d_value" % [i, k], float(a.get("value", 0.0)), 0.0, 100.0, 1.0, "",
			func(v: float) -> void: _step_edit(i, func(d: Dictionary) -> void: ((d["set"] as Array)[kk] as Dictionary)["value"] = v)))
		_row("Set" if k == 0 else "and", h, "A switch takes 1 (on / open) or 0; a control valve its opening in %.")
	var more := Button.new()
	more.text = "Set something else too"
	more.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(more)
	more.pressed.connect(func() -> void: _step_edit(i, func(d: Dictionary) -> void: (d["set"] as Array).append({"tag": "", "value": 0.0}), true))
	_row("", more)
	var until: Dictionary = s.get("until", {}) as Dictionary
	var u := HBoxContainer.new()
	u.add_theme_constant_override("separation", 6)
	u.add_child(_tag_btn("f_step_%d_until_tag" % i, str(until.get("tag", "")), false, func(t: String) -> void:
		_step_edit(i, func(d: Dictionary) -> void:
			var un: Dictionary = d.get("until", {}) as Dictionary
			un["tag"] = t
			if not un.has("op"):
				un["op"] = ">="
			d["until"] = un, true)))
	var ops: Array = []
	for o in ScadaLogic.OPS:
		ops.append([o, o])
	var ob := _option("f_step_%d_until_op" % i, ops, str(until.get("op", ">=")), func(v: String) -> void:
		_step_edit(i, func(d: Dictionary) -> void:
			var un: Dictionary = d.get("until", {}) as Dictionary
			un["op"] = v
			d["until"] = un))
	ob.custom_minimum_size.x = 70
	u.add_child(ob)
	u.add_child(_spin("f_step_%d_until_value" % i, float(until.get("value", 0.0)), -1e6, 1e6, 0.5, "", func(v: float) -> void:
		_step_edit(i, func(d: Dictionary) -> void:
			var un: Dictionary = d.get("until", {}) as Dictionary
			un["value"] = v
			d["until"] = un)))
	_row("Until", u, "Leave the reading unpicked to move on after the wait alone.")
	var times := HBoxContainer.new()
	times.add_theme_constant_override("separation", 6)
	times.add_child(_spin("f_step_%d_min_s" % i, float(s.get("min_s", 0.0)), 0.0, 1e7, 1.0, " s at least",
		func(v: float) -> void: _step_edit(i, func(d: Dictionary) -> void: d["min_s"] = v)))
	times.add_child(_spin("f_step_%d_timeout_s" % i, float(s.get("timeout_s", 0.0)), 0.0, 1e7, 10.0, " s at most",
		func(v: float) -> void: _step_edit(i, func(d: Dictionary) -> void: d["timeout_s"] = v)))
	_row("Takes", times, "At most 0 = no limit. Past its limit the sequence stops and says which step timed out.")
