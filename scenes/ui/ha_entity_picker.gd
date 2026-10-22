extends Node

## Pick one Home Assistant entity (searchable). Used by the timeline's
## Tracks ▾ → Add Home Assistant track → Pick any sensor…; lists the entities
## a track can draw: numbers (sensors, inputs) and on / off states. Calls
## `on_pick(entity_id, friendly_name)` and closes; frees itself when closed.

const ROW_LIMIT := 300
const BINARY_DOMAINS := ["switch", "binary_sensor", "input_boolean", "light", "fan"]

var _svc: Node = null
var _frame: ModalFrame = null
var _search: LineEdit = null
var _domain: OptionButton = null
var _list: VBoxContainer = null
var _note: Label = null
var _on_pick: Callable = Callable()


func open(title: String, subtitle: String, on_pick: Callable) -> void:
	_svc = get_node_or_null("/root/HomeAssistant")
	_on_pick = on_pick
	_frame = ModalFrame.create(title, subtitle, Vector2(820, 640), "ha_entity_picker")
	add_child(_frame)
	_frame.closed.connect(queue_free)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_frame.body.add_child(row)
	_search = LineEdit.new()
	_search.placeholder_text = "Search by name or entity id…"
	_search.clear_button_enabled = true
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.text_changed.connect(func(_t: String) -> void: _rebuild())
	row.add_child(_search)
	_domain = OptionButton.new()
	_domain.custom_minimum_size.x = 160
	_domain.fit_to_longest_item = false
	_domain.item_selected.connect(func(_i: int) -> void: _rebuild())
	row.add_child(_domain)
	_note = Label.new()
	_note.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_note.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	_frame.body.add_child(_note)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 2)
	_frame.body.add_child(_list)
	_frame.add_button("Cancel", ModalFrame.SECONDARY, _frame.close)
	if _svc != null:
		_svc.catalog_updated.connect(_on_catalog)
		if int(_svc.call("catalog_size")) == 0 and bool(_svc.call("is_authed")):
			_svc.call("refresh_catalog")
	_frame.open()
	_fill_domains()
	_rebuild()
	_search.grab_focus.call_deferred()


func _on_catalog() -> void:
	if _frame != null and _frame.is_open():
		_fill_domains()
		_rebuild()


## Entities a track can draw: a number now, or an on / off domain.
static func trackable(row: Dictionary) -> bool:
	if str(row.get("domain", "")) in BINARY_DOMAINS:
		return true
	return not is_nan(HomeAssistantService.entity_number(str(row.get("state", "")))) \
		or not str(row.get("unit", "")).is_empty()


func _rows() -> Array:
	var out: Array = []
	if _svc == null:
		return out
	for r in _svc.call("catalog"):
		if trackable(r):
			out.append(r)
	return out


func _fill_domains() -> void:
	var keep := _domain.get_item_text(_domain.selected) if _domain.selected > 0 else ""
	_domain.clear()
	_domain.add_item("All kinds")
	var doms := {}
	for r in _rows():
		doms[str(r.get("domain", ""))] = true
	var names: Array = doms.keys()
	names.sort()
	for d in names:
		_domain.add_item(str(d))
		if str(d) == keep:
			_domain.select(_domain.item_count - 1)


func _rebuild() -> void:
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
	if _svc == null or not bool(_svc.call("is_authed")):
		_note.text = "Home Assistant is not connected. Connect in Settings → Home Assistant."
		return
	var rows := _rows()
	if rows.is_empty():
		_note.text = "Loading your entities…"
		return
	var q := _search.text.strip_edges().to_lower()
	var dom := _domain.get_item_text(_domain.selected) if _domain.selected > 0 else ""
	var hits: Array = []
	for r in rows:
		if not dom.is_empty() and str(r.get("domain", "")) != dom:
			continue
		if not q.is_empty() and not str(r.get("name", "")).to_lower().contains(q) \
				and not str(r.get("entity_id", "")).to_lower().contains(q):
			continue
		hits.append(r)
	hits.sort_custom(func(a, b): return str(a.get("name", "")).to_lower() < str(b.get("name", "")).to_lower())
	for i in mini(hits.size(), ROW_LIMIT):
		var r: Dictionary = hits[i]
		var eid := str(r.get("entity_id", ""))
		var val := str(r.get("state", ""))
		if not str(r.get("unit", "")).is_empty():
			val += " " + str(r["unit"])
		var b := Button.new()
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.focus_mode = Control.FOCUS_NONE
		UITheme.style_button(b)
		b.text = "%s     %s     %s" % [str(r.get("name", eid)), val, eid]
		b.tooltip_text = "%s\n%s\nnow: %s\nClick to add it as a timeline track." % [str(r.get("name", eid)), eid, val]
		b.pressed.connect(_pick.bind(eid, str(r.get("name", eid))))
		_list.add_child(b)
	_note.text = "%s%s" % [UiText.count(hits.size(), "sensor"),
		(" (showing %d — search to narrow)" % ROW_LIMIT) if hits.size() > ROW_LIMIT else ""]


func _pick(eid: String, label: String) -> void:
	if _on_pick.is_valid():
		_on_pick.call(eid, label)
	_frame.close()
