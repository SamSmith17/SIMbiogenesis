extends Node
## The Hardware window (plans/SCADA_PROCESS_PLAN.md, Phase 7): which tags
## drive which Home Assistant entities, their safe states, and the ARM switch.
## Nothing is sent until the outputs are armed, and they can only be armed in
## Live mode with Home Assistant connected. Opened by
## SystemGraphView.open_outputs_panel (the Process lens's Hardware button and
## its ARMED bar, the HUD chip).
##
##   open(view, hub), is_open(), close(), show_tab("links" | "journal")
##   button(name), field(name)    for checks: arm, disarm, add_link, copy_yaml,
##                                tab_<tab>, del_<id>, pick_<id>,
##                                o_<id>_<key> (tag, entity_id, enabled,
##                                invert, safe, scale, offset, min, max),
##                                hb_entity, hb_s, hb_timeout
##   last_yaml()

const TABS := [["links", "Outputs"], ["journal", "Journal"]]
const SAFE_CHOICES := [["off", "Off / shut"], ["on", "On / open"], ["hold", "Leave as it is"], ["value", "A value"]]
const C_ARMED := Color(0.96, 0.42, 0.24)

var _view: Node = null
var _hub: Node = null
var _frame: ModalFrame = null
var _tab := "links"
var _tab_btns: Dictionary = {}
var _status: Label = null
var _arm_btn: Button = null
var _box: VBoxContainer = null
var _row_labels: Dictionary = {}
var _acc := 0.0
var _jsig := ""
var _yaml := ""


func open(view: Node, hub: Node) -> void:
	_view = view
	_hub = hub
	_frame = ModalFrame.create("Hardware", "Let the game switch real devices through Home Assistant. Nothing is sent until you arm it, and it lets go the moment you leave Live mode.",
		Vector2(1120, 740), "scada_outputs_panel")
	_frame.content_max_w = 0.0
	add_child(_frame)
	_frame.closed.connect(queue_free)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 10)
	_frame.body.add_child(top)
	_status = Label.new()
	_status.name = "arm_status"
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size.x = 300
	top.add_child(_status)
	_arm_btn = Button.new()
	_arm_btn.name = "arm"
	_arm_btn.focus_mode = Control.FOCUS_NONE
	_arm_btn.custom_minimum_size = Vector2(170, 40)
	UITheme.style_button(_arm_btn)
	_arm_btn.pressed.connect(_on_arm)
	top.add_child(_arm_btn)
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
	if _hub != null and not _hub.is_connected("outputs_changed", _on_changed):
		_hub.connect("outputs_changed", _on_changed)
	show_tab("links")


func close() -> void:
	if _frame != null and is_instance_valid(_frame):
		_frame.close()


func is_open() -> bool:
	return _frame != null and is_instance_valid(_frame) and _frame.visible


func button(n: String) -> Button:
	return (_frame.find_child(n, true, false) as Button) if _frame != null else null


func field(n: String) -> Control:
	return (_frame.find_child(n, true, false) as Control) if _frame != null else null


func last_yaml() -> String:
	return _yaml


func show_tab(which: String) -> void:
	_tab = which if which in ["links", "journal"] else "links"
	for k in _tab_btns:
		(_tab_btns[k] as Button).set_pressed_no_signal(str(k) == _tab)
	_rebuild()


func _on_changed() -> void:
	_refresh_status()
	if _tab == "journal":
		_rebuild()


func _process(delta: float) -> void:
	if not is_open():
		return
	_acc += delta
	if _acc < 0.5:
		return
	_acc = 0.0
	_refresh_status()
	if _tab == "links":
		_refresh_rows()
	elif str((_hub.call("output_journal") as Array).size()) != _jsig:
		_rebuild()


func _on_arm() -> void:
	if bool(_hub.call("outputs_armed")):
		_hub.call("disarm", "by hand")
	else:
		var why := str(_hub.call("arm"))
		if not why.is_empty() and _view != null and _view.has_method("scada_output_toast"):
			_view.call("scada_output_toast", why, false)
	_refresh_status()


func _refresh_status() -> void:
	if _hub == null or _status == null:
		return
	var armed := bool(_hub.call("outputs_armed"))
	_arm_btn.name = "disarm" if armed else "arm"
	_arm_btn.text = "Disarm" if armed else "Arm the outputs"
	if armed:
		_status.text = "ARMED. The game is driving real devices. Disarm puts each one to its safe state."
		_status.add_theme_color_override("font_color", C_ARMED)
		_arm_btn.disabled = false
		_arm_btn.tooltip_text = "Put every output to its safe state and stop sending"
		return
	var why := str(_hub.call("arm_refusal"))
	_status.add_theme_color_override("font_color", UITheme.C_TEXT_M if not why.is_empty() else UITheme.C_TEXT)
	var last := str(_hub.call("disarm_reason"))
	var tail := (" Last disarmed: %s." % last) if not last.is_empty() else ""
	_status.text = ("Not armed. %s%s" % [why, tail]) if not why.is_empty() else "Not armed. Ready: Live mode is on and Home Assistant is connected.%s" % tail
	_arm_btn.disabled = not why.is_empty()
	_arm_btn.tooltip_text = why


func _clear() -> void:
	_row_labels = {}
	for c in _box.get_children():
		_box.remove_child(c)
		c.queue_free()


func _rebuild() -> void:
	if _hub == null:
		return
	_clear()
	_refresh_status()
	if _tab == "journal":
		_build_journal()
	else:
		_build_links()


func _btn(n: String, text: String, tip: String, cb: Callable) -> Button:
	var b := Button.new()
	b.name = n
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(b)
	b.pressed.connect(cb)
	return b


func _links() -> Array:
	return (_hub.call("output_links") as Array)


func _put(id: String, key: String, value: Variant, rebuild: bool = false) -> void:
	var all := _links()
	for l in all:
		if str(l["id"]) == id:
			l[key] = value
	_hub.call("set_output_links", all)
	if rebuild:
		_rebuild()
	else:
		_refresh_checks()


func _tag_text(tag: String) -> String:
	if tag.is_empty():
		return "Pick a tag…"
	var t: Dictionary = (_hub.call("book") as ScadaTags).tag(tag)
	return "%s · %s" % [str(t.get("group", "")), str(t.get("label", tag))] if not t.is_empty() else tag


func _spin(n: String, v: float, lo: float, hi: float, step: float, prefix: String, on: Callable, tip: String = "") -> SpinBox:
	var sp := SpinBox.new()
	sp.name = n
	sp.min_value = lo
	sp.max_value = hi
	sp.step = step
	sp.value = v
	sp.prefix = prefix
	sp.tooltip_text = tip
	sp.custom_minimum_size.x = 110.0 + float(prefix.length()) * 8.0
	sp.value_changed.connect(on)
	return sp


var _checks_box: VBoxContainer = null

func _refresh_checks() -> void:
	if _checks_box == null or not is_instance_valid(_checks_box):
		return
	for c in _checks_box.get_children():
		_checks_box.remove_child(c)
		c.queue_free()
	for c2 in _hub.call("output_checks"):
		var l := Label.new()
		l.text = ("✗ " if str(c2["level"]) == "error" else "⚠ ") + str(c2["text"])
		l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		l.add_theme_color_override("font_color", UITheme.C_ERROR if str(c2["level"]) == "error" else UITheme.C_WARN)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_checks_box.add_child(l)


## The entities Home Assistant has that the game can drive, matching `text`.
func _entity_choices(text: String) -> Array:
	var out: Array = []
	var ha := get_node_or_null("/root/HomeAssistant")
	if ha == null or not ha.has_method("catalog"):
		return out
	var q := text.strip_edges().to_lower()
	for e in ha.call("catalog"):
		var eid := str(e.get("entity_id", ""))
		if not ScadaOutputs.supported(eid):
			continue
		var nm := str(e.get("name", e.get("friendly_name", "")))
		if q.is_empty() or eid.to_lower().contains(q) or nm.to_lower().contains(q):
			out.append([eid, nm])
		if out.size() >= 40:
			break
	return out


func _build_links() -> void:
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	head.add_child(_btn("add_link", "Add an output", "A tag in the game and the entity it drives", func() -> void:
		var all := _links()
		all.append(ScadaOutputs.make(str(_hub.call("new_output_id"))))
		_hub.call("set_output_links", all)
		_rebuild()))
	_box.add_child(head)
	_checks_box = VBoxContainer.new()
	_box.add_child(_checks_box)
	var links := _links()
	if links.is_empty():
		_box.add_child(EmptyState.row("plug", "No outputs yet. Add one: pick a pump's switch or a valve's opening, and the Home Assistant entity that should follow it."))
	for l in links:
		_box.add_child(_link_card(l))
	# The heartbeat and the watchdog.
	_box.add_child(SectionHeader.make("If the game stops", "a watchdog in Home Assistant puts the outputs safe"))
	var st: Dictionary = _hub.call("output_settings")
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 6)
	var he := LineEdit.new()
	he.name = "hb_entity"
	he.placeholder_text = "input_boolean.simbio_heartbeat"
	he.text = str(st.get("heartbeat_entity", ""))
	he.tooltip_text = "A toggle (or button) helper the game touches while armed. Make one in Home Assistant: Settings → Devices & services → Helpers."
	he.custom_minimum_size.x = 320
	he.text_submitted.connect(func(t: String) -> void: _put_setting("heartbeat_entity", t))
	he.focus_exited.connect(func() -> void: _put_setting("heartbeat_entity", he.text))
	hb.add_child(he)
	hb.add_child(_spin("hb_s", float(st.get("heartbeat_s", 10.0)), 2.0, 300.0, 1.0, "every ", func(x: float) -> void: _put_setting("heartbeat_s", x), "Seconds between touches"))
	hb.add_child(_spin("hb_timeout", float(st.get("timeout_s", 45.0)), 10.0, 3600.0, 5.0, "safe after ", func(x: float) -> void: _put_setting("timeout_s", x), "Seconds of silence before Home Assistant puts the outputs safe"))
	hb.add_child(_btn("copy_yaml", "Copy the watchdog automation", "The Home Assistant automation that puts every output to its safe state when the heartbeat stops. Paste it into automations.yaml.", func() -> void:
		var r: Dictionary = _hub.call("watchdog_yaml")
		_yaml = str(r.get("text", ""))
		DisplayServer.clipboard_set(_yaml)
		if _view != null and _view.has_method("scada_output_toast"):
			_view.call("scada_output_toast", "Watchdog automation copied (also saved to %s)." % str(r.get("path", "")), false)))
	_box.add_child(hb)
	_refresh_checks()
	_refresh_rows()


func _put_setting(key: String, value: Variant) -> void:
	var st: Dictionary = _hub.call("output_settings")
	if st.get(key) == value:
		return
	st[key] = value
	_hub.call("set_output_settings", st)
	_refresh_checks()


func _link_card(l: Dictionary) -> Control:
	var id := str(l["id"])
	var card := PanelContainer.new()
	card.name = "out_%s" % id
	card.add_theme_stylebox_override("panel", UITheme.card_style())
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	card.add_child(v)
	var a := HBoxContainer.new()
	a.add_theme_constant_override("separation", 6)
	v.add_child(a)
	var tb := Button.new()
	tb.name = "o_%s_tag" % id
	tb.text = _tag_text(str(l["tag"]))
	tb.tooltip_text = str(l["tag"])
	tb.clip_text = true
	tb.custom_minimum_size.x = 280
	tb.alignment = HORIZONTAL_ALIGNMENT_LEFT
	tb.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(tb)
	tb.pressed.connect(func() -> void:
		if _view != null and _view.has_method("open_tag_browser"):
			_view.call("open_tag_browser", {"title": "Pick the tag this output follows",
				"pick": func(t: Dictionary) -> void: _put(id, "tag", str(t.get("id", "")), true)}))
	a.add_child(tb)
	var arrow := Label.new()
	arrow.text = "drives"
	arrow.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	a.add_child(arrow)
	var ee := LineEdit.new()
	ee.name = "o_%s_entity_id" % id
	ee.placeholder_text = "switch.pump"
	ee.text = str(l["entity_id"])
	ee.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ee.custom_minimum_size.x = 220
	ee.text_submitted.connect(func(t: String) -> void: _put(id, "entity_id", t.strip_edges(), true))
	ee.focus_exited.connect(func() -> void:
		if ee.text.strip_edges() != str(l["entity_id"]):
			_put(id, "entity_id", ee.text.strip_edges(), true))
	a.add_child(ee)
	var pick := MenuButton.new()
	pick.name = "pick_%s" % id
	pick.text = "Pick…"
	pick.flat = false
	pick.focus_mode = Control.FOCUS_NONE
	pick.tooltip_text = "Entities Home Assistant has that the game can drive (type in the box to narrow them)"
	UITheme.style_button(pick)
	pick.about_to_popup.connect(func() -> void:
		var pm := pick.get_popup()
		pm.clear()
		var ch := _entity_choices(ee.text if not ScadaOutputs.supported(ee.text) else "")
		if ch.is_empty():
			pm.add_item("Nothing to pick: connect Home Assistant, or type the entity id")
			pm.set_item_disabled(0, true)
		for c in ch:
			pm.add_item("%s   %s" % [str(c[0]), str(c[1])])
			pm.set_item_metadata(pm.item_count - 1, str(c[0])))
	pick.get_popup().index_pressed.connect(func(i: int) -> void:
		var md: Variant = pick.get_popup().get_item_metadata(i)
		if md != null:
			_put(id, "entity_id", str(md), true))
	a.add_child(pick)
	var en := CheckBox.new()
	en.name = "o_%s_enabled" % id
	en.text = "On"
	en.button_pressed = bool(l["enabled"])
	en.toggled.connect(func(on: bool) -> void: _put(id, "enabled", on))
	a.add_child(en)
	var del := IconButton.make("trash-2", "Remove this output", func() -> void:
		var all: Array = _links().filter(func(x: Dictionary) -> bool: return str(x["id"]) != id)
		_hub.call("set_output_links", all)
		_rebuild())
	del.name = "del_%s" % id
	a.add_child(del)
	# Second line: safe state, shaping, what it would send.
	var b := HBoxContainer.new()
	b.add_theme_constant_override("separation", 6)
	v.add_child(b)
	var sl := Label.new()
	sl.text = "Safe state"
	sl.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	b.add_child(sl)
	var so := OptionButton.new()
	so.name = "o_%s_safe" % id
	so.tooltip_text = "What it is put to when the outputs are disarmed, and by the watchdog"
	var cur := str(l["safe"]) if l["safe"] is String else "value"
	for sc in SAFE_CHOICES:
		so.add_item(str(sc[1]))
		if str(sc[0]) == cur:
			so.select(so.item_count - 1)
	so.item_selected.connect(func(i: int) -> void:
		var k := str(SAFE_CHOICES[i][0])
		_put(id, "safe", 0.0 if k == "value" else k, true))
	b.add_child(so)
	if not (l["safe"] is String):
		b.add_child(_spin("o_%s_safe_value" % id, float(l["safe"]), -1e6, 1e6, 0.5, "", func(x: float) -> void: _put(id, "safe", x)))
	var d := ScadaOutputs.domain_of(str(l["entity_id"]))
	if d in ScadaOutputs.BINARY_DOMAINS or d in ScadaOutputs.POSITION_DOMAINS or d.is_empty():
		var inv := CheckBox.new()
		inv.name = "o_%s_invert" % id
		inv.text = "Other way round"
		inv.tooltip_text = "Send off when the tag is on (a normally-open valve, a relay wired the other way)"
		inv.button_pressed = bool(l["invert"])
		inv.toggled.connect(func(on: bool) -> void: _put(id, "invert", on))
		b.add_child(inv)
	if d in ScadaOutputs.NUMBER_DOMAINS or d in ScadaOutputs.POSITION_DOMAINS:
		b.add_child(_spin("o_%s_scale" % id, float(l["scale"]), -1000.0, 1000.0, 0.01, "× ", func(x: float) -> void: _put(id, "scale", x), "The tag's value times this"))
		b.add_child(_spin("o_%s_offset" % id, float(l["offset"]), -1e6, 1e6, 0.1, "+ ", func(x: float) -> void: _put(id, "offset", x), "…plus this"))
		b.add_child(_spin("o_%s_min" % id, float(l["min"]), -1e6, 1e6, 0.5, "min ", func(x: float) -> void: _put(id, "min", x), "Never send less than this (with max above min)"))
		b.add_child(_spin("o_%s_max" % id, float(l["max"]), -1e6, 1e6, 0.5, "max ", func(x: float) -> void: _put(id, "max", x), "Never send more than this (0 with min 0 = no limits)"))
	var live := Label.new()
	live.name = "o_%s_live" % id
	live.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	live.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	live.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	live.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	live.clip_text = true
	b.add_child(live)
	_row_labels[id] = live
	return card


func _refresh_rows() -> void:
	if _row_labels.is_empty() or _hub == null:
		return
	var rows: Dictionary = _hub.call("output_rows")
	var armed := bool(_hub.call("outputs_armed"))
	for id in _row_labels.keys():
		var lb := _row_labels[id] as Label
		if not is_instance_valid(lb):
			continue
		var r: Dictionary = rows.get(id, {})
		var t := "would send: %s" % str(r.get("value", ""))
		if armed and float(r.get("at_s", -1.0)) >= 0.0:
			t = "sent %s, %s ago" % [str(r.get("sent", "")), ("%d s" % int(float(r["at_s"])) if float(r["at_s"]) < 90.0 else "%d min" % int(float(r["at_s"]) / 60.0))]
		elif armed:
			t = "armed · " + t
		if lb.text != t:
			lb.text = t


func _build_journal() -> void:
	var j: Array = _hub.call("output_journal")
	_jsig = str(j.size())
	if j.is_empty():
		_box.add_child(EmptyState.row("list", "Nothing sent yet. Every command the game sends while armed is listed here."))
		return
	for k in range(j.size() - 1, maxi(j.size() - 120, -1), -1):
		var e: Dictionary = j[k]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		var tl := Label.new()
		var dt := Time.get_datetime_dict_from_unix_time(int(float(e.get("unix", 0.0))) + int(Time.get_time_zone_from_system().get("bias", 0)) * 60)
		tl.text = "%02d:%02d:%02d" % [int(dt["hour"]), int(dt["minute"]), int(dt["second"])]
		tl.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		tl.add_theme_font_override("font", UITheme.font("regular", true))
		row.add_child(tl)
		var tx := Label.new()
		tx.text = str(e.get("text", ""))
		tx.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tx.clip_text = true
		row.add_child(tx)
		_box.add_child(row)
