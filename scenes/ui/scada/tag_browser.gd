extends Node

## The tag browser (plans/SCADA_PROCESS_PLAN.md, Phase 1): every value on the
## site a mimic can show, a rule can read or a control block can command —
## tank levels, machine switches, pipe flows, greenhouse air, board sensors,
## followed Home Assistant entities — searchable, with live values.
##
##   open(hub)                      browse; rows offer "Add to timeline" and,
##                                  for a switch, On / Off
##   open(hub, {pick: Callable})    pick one: on_pick(tag) and close
##   open(hub, {writable: true})    only tags that can be commanded
##
## Frees itself when closed. `rows()` / `row_button(id, name)` are for checks.

const ROW_LIMIT := 250
const REFRESH_S := 1.0
const SOURCES := [["", "Everything"], ["graph", "Graph"], ["site", "Site power"], ["logic", "Logic"], ["alarm", "Alarms"],
	["esp", "Boards"], ["tc", "Processes"], ["ha", "Home Assistant"]]

var _hub: Node = null
var _frame: ModalFrame = null
var _search: LineEdit = null
var _source: OptionButton = null
var _list: VBoxContainer = null
var _note: Label = null
var _opts: Dictionary = {}
var _value_labels: Dictionary = {}   # tag id -> Label
var _row_nodes: Dictionary = {}      # tag id -> HBoxContainer
var _acc := 0.0


func open(hub: Node, opts: Dictionary = {}) -> void:
	_hub = hub
	_opts = opts
	var picking := opts.has("pick")
	_frame = ModalFrame.create(str(opts.get("title", "Pick a tag" if picking else "Tags")),
		str(opts.get("subtitle", "Every live value on this site. Rules, alarms, trends and process pictures read these.")),
		Vector2(900, 680), "scada_tag_browser")
	add_child(_frame)
	_frame.closed.connect(queue_free)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_frame.body.add_child(row)
	_search = LineEdit.new()
	_search.name = "search"
	_search.placeholder_text = "Search by name, node or unit…"
	_search.clear_button_enabled = true
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.text_changed.connect(func(_t: String) -> void: _rebuild())
	row.add_child(_search)
	_source = OptionButton.new()
	_source.name = "source"
	_source.custom_minimum_size.x = 170
	_source.fit_to_longest_item = false
	for s in SOURCES:
		_source.add_item(str(s[1]))
	_source.item_selected.connect(func(_i: int) -> void: _rebuild())
	row.add_child(_source)
	_note = Label.new()
	_note.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_note.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	_frame.body.add_child(_note)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 2)
	_frame.body.add_child(_list)
	_frame.add_button("Cancel" if picking else "Close", ModalFrame.SECONDARY, _frame.close)
	_frame.open()
	if _hub != null and _hub.get("modal_layer") != null:
		_frame.layer = int(_hub.get("modal_layer")) + 1
	if _hub != null:
		_hub.call("refresh")
	_rebuild()
	_search.grab_focus.call_deferred()


func _process(delta: float) -> void:
	if _frame == null or not _frame.is_open() or _hub == null:
		return
	_acc += delta
	if _acc < REFRESH_S:
		return
	_acc = 0.0
	var book: ScadaTags = _hub.call("book")
	for id in _value_labels:
		var lbl: Label = _value_labels[id]
		if is_instance_valid(lbl):
			_paint_value(lbl, book.tag(str(id)))


func _matches() -> Array:
	if _hub == null:
		return []
	var book: ScadaTags = _hub.call("book")
	var src := str(SOURCES[maxi(_source.selected, 0)][0])
	var out: Array = []
	for t: Dictionary in book.search(_search.text, bool(_opts.get("writable", false))):
		if src.is_empty() or str(t.get("source", "")) == src:
			out.append(t)
	return out


func _rebuild() -> void:
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
	_value_labels.clear()
	_row_nodes.clear()
	var tags := _matches()
	if tags.is_empty():
		_note.text = "No tags match." if _hub != null else "No graph is loaded."
		return
	_note.text = "%s%s" % [UiText.count(tags.size(), "tag"),
		" (showing the first %d; search to narrow it)" % ROW_LIMIT if tags.size() > ROW_LIMIT else ""]
	var last_group := "\n"
	var shown := 0
	for t: Dictionary in tags:
		if shown >= ROW_LIMIT:
			break
		var group := str(t.get("group", ""))
		if group != last_group:
			last_group = group
			_list.add_child(SectionHeader.make(group if not group.is_empty() else "Other"))
		_list.add_child(_row(t))
		shown += 1


func _row(t: Dictionary) -> Control:
	var id := str(t["id"])
	var row := HBoxContainer.new()
	row.name = "row_" + id.replace(".", "_")
	row.add_theme_constant_override("separation", 8)
	var name_lbl := Label.new()
	name_lbl.text = str(t["label"])
	name_lbl.custom_minimum_size.x = 190
	name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(name_lbl)
	var val := Label.new()
	val.name = "value"
	val.custom_minimum_size.x = 120
	val.add_theme_font_override("font", UITheme.font("semibold", true))
	row.add_child(val)
	_paint_value(val, t)
	_value_labels[id] = val
	var id_lbl := Label.new()
	id_lbl.text = id
	id_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	id_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	id_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	id_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	id_lbl.tooltip_text = "The name rules and exports use for this value."
	id_lbl.mouse_filter = Control.MOUSE_FILTER_STOP
	row.add_child(id_lbl)
	if _opts.has("pick"):
		row.add_child(_btn("pick", "Use", func() -> void:
			var cb: Callable = _opts["pick"]
			_frame.close()
			if cb.is_valid():
				cb.call(t), "Pick %s" % str(t["label"])))
	else:
		if str(t.get("kind", "")) == ScadaTags.KIND_SWITCH and bool(t.get("writable", false)):
			row.add_child(_btn("on", "On", func() -> void: _command(id, 1.0), "Switch %s on" % str(t["label"])))
			row.add_child(_btn("off", "Off", func() -> void: _command(id, 0.0), "Switch %s off" % str(t["label"])))
		row.add_child(_btn("track", "Add to timeline", func() -> void: _add_track(t), "Add %s as a timeline track" % str(t["label"])))
	_row_nodes[id] = row
	return row


func _btn(node_name: String, text: String, cb: Callable, tip: String = "") -> Button:
	var b := Button.new()
	b.name = node_name
	b.text = text
	b.tooltip_text = tip
	UITheme.style_button(b)
	b.pressed.connect(cb)
	return b


func _paint_value(lbl: Label, t: Dictionary) -> void:
	var txt := ScadaTags.display(t)
	if lbl.text != txt:
		lbl.text = txt
	var col := UITheme.C_TEXT
	var low := txt.to_lower()
	if t.is_empty() or not bool(t.get("available", false)):
		col = UITheme.C_TEXT_M
	elif low == "blocked" or low == "starved" or low == "overflow" or low == "fault":
		col = UITheme.C_WARN
	elif low == "on" or low == "ok" or low == "running":
		col = UITheme.C_OK
	lbl.add_theme_color_override("font_color", col)


func _command(id: String, v: float) -> void:
	if _hub != null and bool(_hub.call("command", id, v)):
		var book: ScadaTags = _hub.call("book")
		var lbl: Label = _value_labels.get(id, null)
		if lbl != null and is_instance_valid(lbl):
			_paint_value(lbl, book.tag(id))


func _add_track(t: Dictionary) -> void:
	var tl := ServiceLocator.timeline_ui()
	if tl != null and tl.has_method("add_tag_track"):
		tl.call("add_tag_track", str(t["id"]), track_label(t))
		var main := ServiceLocator.main()
		if main != null and main.has_method("show_toast"):
			main.call("show_toast", "Added “%s” to the timeline" % track_label(t))


static func track_label(t: Dictionary) -> String:
	var g := str(t.get("group", ""))
	return str(t.get("label", t.get("id", ""))) if g.is_empty() else "%s · %s" % [g, str(t.get("label", ""))]


# ── for checks ──────────────────────────────────────────────────────────────

func rows() -> Array:
	return _row_nodes.keys()


func row_button(id: String, button: String) -> Button:
	var row: Node = _row_nodes.get(id, null)
	return row.get_node_or_null(button) as Button if row != null else null


func set_search(text: String) -> void:
	_search.text = text
	_rebuild()


func is_open() -> bool:
	return _frame != null and _frame.is_open()


func close() -> void:
	if _frame != null:
		_frame.close()
