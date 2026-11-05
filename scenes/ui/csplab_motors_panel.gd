extends VBoxContainer

## "Motors & Home Assistant" in the solar concentrator designer: every drive
## the concentrator turns (CspLabActuators.channels), its angle now, and —
## for a placed concentrator — which Home Assistant entity each is sent to
## so a real motor can follow the simulation. The settings live on the prop
## record as `csplab_ha`; CspLabRuntime does the sending.
##
## The owner (the modal) answers `motors_source()` → {chans, live, status,
## name, prop_id} and `motors_main()` → Main.

const MAX_EDIT_ROWS := 24
const SAVE_DELAY_S := 0.6

var owner_modal: Node = null
var _cfg: Dictionary = {}
var _prop_id := ""
var _rows_key := ""
var _value_lbls: Dictionary = {}
var _rows_box: VBoxContainer
var _head_lbl: Label
var _status_lbl: Label
var _send_row: FormRow
var _mode_row: FormRow
var _db_row: FormRow
var _int_row: FormRow
var _fill_btn: Button
var _yaml_btn: Button
var _note_lbl: Label
var _dirty_t := -1.0
var _last_chans: Array = []


func setup(modal: Node) -> void:
	owner_modal = modal
	add_theme_constant_override("separation", UITheme.SPACE_SM)
	_head_lbl = _small("", UITheme.C_TEXT_S)
	add_child(_head_lbl)
	_rows_box = VBoxContainer.new()
	_rows_box.add_theme_constant_override("separation", UITheme.SPACE_SM)
	add_child(_rows_box)
	add_child(SectionHeader.make("Send to Home Assistant", "house"))
	_send_row = FormRow.check("Send", "Send these angles", func(on: bool) -> void: _set_cfg("enabled", on),
		"Each drive's angle goes to its entity whenever it moves past the deadband", "ha_send")
	add_child(_send_row)
	var modes: Array = []
	for k in CspLabActuators.MODES:
		modes.append([k, str(CspLabActuators.MODES[k])])
	_mode_row = FormRow.option("When", modes, func(m: Variant) -> void: _set_cfg("mode", str(m)),
		"Live mode only: the real motor moves with the real sun. Always: it follows the simulation, at any speed you run it — use a slow clock with real hardware.", "ha_mode")
	add_child(_mode_row)
	_db_row = FormRow.spin("Deadband", 0.0, 20.0, 0.1, "°", func(v: float) -> void: _set_cfg("deadband_deg", v),
		"Send only when an angle has moved at least this far since the last send", "ha_deadband")
	add_child(_db_row)
	_int_row = FormRow.spin("At most every", 0.5, 3600.0, 0.5, "s", func(v: float) -> void: _set_cfg("min_interval_s", v),
		"The shortest time between sends (a motor and Home Assistant both like a calm rate)", "ha_interval")
	add_child(_int_row)
	_status_lbl = _small("", UITheme.C_TEXT_M)
	add_child(_status_lbl)
	var btns := HFlowContainer.new()
	btns.add_theme_constant_override("h_separation", UITheme.SPACE_SM)
	_fill_btn = Button.new()
	_fill_btn.text = "Name the helpers"
	_fill_btn.tooltip_text = "Fill every empty entity with input_number.<design>_<drive> — the helpers the YAML below declares"
	UITheme.style_button(_fill_btn)
	_fill_btn.pressed.connect(_on_fill)
	btns.add_child(_fill_btn)
	_yaml_btn = Button.new()
	_yaml_btn.text = "Copy Home Assistant YAML"
	_yaml_btn.tooltip_text = "input_number helpers for every drive and an example automation that hands one to a motor"
	UITheme.style_button(_yaml_btn)
	_yaml_btn.pressed.connect(_on_yaml)
	btns.add_child(_yaml_btn)
	add_child(btns)
	_note_lbl = _small("", UITheme.C_TEXT_M)
	add_child(_note_lbl)


func _small(t: String, col: Color) -> Label:
	var l := Label.new()
	l.text = t
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	l.add_theme_color_override("font_color", col)
	return l


## Read the bound prop's settings (on open, and whenever the bound prop
## changes).
func reload() -> void:
	var src: Dictionary = owner_modal.call("motors_source")
	_prop_id = str(src.get("prop_id", ""))
	_cfg = {}
	if not _prop_id.is_empty():
		var rec := PlacedPropService.get_prop_record(owner_modal.call("motors_main") as Node, _prop_id)
		_cfg = (rec.get("csplab_ha", {}) as Dictionary).duplicate(true)
	_cfg = CspLabActuators.normalized(_cfg)
	_rows_key = ""
	_sync_globals()
	refresh()


func _sync_globals() -> void:
	_send_row.set_value(bool(_cfg["enabled"]))
	_mode_row.set_value(str(_cfg["mode"]))
	_db_row.set_value(float(_cfg["deadband_deg"]))
	_int_row.set_value(float(_cfg["min_interval_s"]))
	var bound := not _prop_id.is_empty()
	for r in [_send_row, _mode_row, _db_row, _int_row]:
		var c: Control = (r as FormRow).control
		if c is BaseButton:
			(c as BaseButton).disabled = not bound
		elif c is SpinBox:
			(c as SpinBox).editable = bound
	_fill_btn.disabled = not bound


## Called a few times a second by the modal: the angles now, the status.
func refresh() -> void:
	if owner_modal == null:
		return
	var src: Dictionary = owner_modal.call("motors_source")
	var chans: Array = src.get("chans", []) as Array
	_last_chans = chans
	var bound := not _prop_id.is_empty()
	_head_lbl.text = ("Live, from the placed concentrator (the world's clock)." if bool(src.get("live", false))
		else "At the moment chosen above (the studio's sun).")
	var key := ""
	for chv in chans:
		key += str((chv as Dictionary)["id"]) + ","
	key += "|%s" % _prop_id
	if key != _rows_key:
		_rows_key = key
		_build_rows(chans, bound)
	for chv in chans:
		var ch: Dictionary = chv
		var id := str(ch["id"])
		if _value_lbls.has(id):
			(_value_lbls[id] as Label).text = "%.1f°" % float(ch["deg"])
	if chans.is_empty():
		_status_lbl.text = "Nothing on this concentrator moves (a fixed or level optic): there is nothing to drive."
	elif not bound:
		_status_lbl.text = "Place the concentrator, or open the designer from a placed one, to send these to Home Assistant."
	else:
		_status_lbl.text = str(src.get("status", ""))
	_note_lbl.text = "Values are degrees in the concentrator's own frame: azimuth 0 is the way the placed prop's north faces. Use Offset and Invert to match where your motor counts from."
	if _dirty_t >= 0.0 and Time.get_ticks_msec() / 1000.0 - _dirty_t > SAVE_DELAY_S:
		_save()


func _build_rows(chans: Array, bound: bool) -> void:
	for c in _rows_box.get_children():
		_rows_box.remove_child(c)
		c.queue_free()
	_value_lbls.clear()
	if chans.is_empty():
		return
	var nm := str((owner_modal.call("motors_source") as Dictionary).get("name", "concentrator"))
	var links: Dictionary = _cfg["channels"]
	for i in chans.size():
		var ch: Dictionary = chans[i]
		var id := str(ch["id"])
		var card := VBoxContainer.new()
		card.add_theme_constant_override("separation", 2)
		var head := HBoxContainer.new()
		var nl := Label.new()
		nl.text = str(ch["label"])
		nl.tooltip_text = str(ch["tip"])
		nl.mouse_filter = Control.MOUSE_FILTER_PASS
		nl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		nl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		head.add_child(nl)
		var vl := Label.new()
		vl.name = "deg_" + id
		vl.add_theme_font_override("font", UITheme.font("semibold", true))
		vl.add_theme_color_override("font_color", UITheme.C_AMBER)
		vl.text = "%.1f°" % float(ch["deg"])
		head.add_child(vl)
		var rl := Label.new()
		rl.text = "  %.0f…%.0f°" % [float(ch["min"]), float(ch["max"])]
		rl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		rl.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		head.add_child(rl)
		card.add_child(head)
		_value_lbls[id] = vl
		if i >= MAX_EDIT_ROWS:
			_rows_box.add_child(card)
			continue
		var l: Dictionary = links.get(id, {}) as Dictionary
		var ent := LineEdit.new()
		ent.name = "entity_" + id
		ent.placeholder_text = CspLabActuators.default_entity(nm, id)
		ent.text = str(l.get("entity_id", ""))
		ent.tooltip_text = "The entity this drive is sent to: input_number.* or number.* (the angle), cover.* or valve.* (a position 0–100 % of the range)"
		ent.editable = bound
		ent.text_changed.connect(func(t: String) -> void: _set_link(id, "entity_id", t.strip_edges()))
		card.add_child(ent)
		var opts := HBoxContainer.new()
		opts.add_theme_constant_override("separation", UITheme.SPACE_SM)
		var inv := CheckBox.new()
		inv.text = "Invert"
		inv.button_pressed = bool(l.get("invert", false))
		inv.disabled = not bound
		inv.tooltip_text = "Send the angle with its sign turned round (a motor that counts the other way)"
		inv.toggled.connect(func(on: bool) -> void: _set_link(id, "invert", on))
		opts.add_child(inv)
		opts.add_child(_tiny("Offset"))
		var off := SpinBox.new()
		off.min_value = -720.0
		off.max_value = 720.0
		off.step = 0.1
		off.suffix = "°"
		off.value = float(l.get("offset", 0.0))
		off.editable = bound
		off.tooltip_text = "Added after scale: where your motor's zero is"
		off.value_changed.connect(func(v: float) -> void: _set_link(id, "offset", v))
		opts.add_child(off)
		opts.add_child(_tiny("×"))
		var sc := SpinBox.new()
		sc.min_value = -1000.0
		sc.max_value = 1000.0
		sc.step = 0.01
		sc.value = float(l.get("scale", 1.0))
		sc.editable = bound
		sc.tooltip_text = "Multiplies the angle (e.g. steps per degree, or mm of actuator stroke per degree)"
		sc.value_changed.connect(func(v: float) -> void: _set_link(id, "scale", v))
		opts.add_child(sc)
		card.add_child(opts)
		_rows_box.add_child(card)
	if chans.size() > MAX_EDIT_ROWS:
		_rows_box.add_child(_small("%d drives in all; the first %d can be linked here. The YAML covers every one." % [chans.size(), MAX_EDIT_ROWS], UITheme.C_TEXT_M))


func _tiny(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	l.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	return l


func _set_cfg(key: String, v: Variant) -> void:
	_cfg[key] = v
	_mark_dirty()


func _set_link(id: String, key: String, v: Variant) -> void:
	var links: Dictionary = _cfg["channels"]
	if not links.has(id):
		links[id] = {"entity_id": "", "scale": 1.0, "offset": 0.0, "invert": false, "min": 0.0, "max": 0.0, "enabled": true}
	(links[id] as Dictionary)[key] = v
	_mark_dirty()


func _mark_dirty() -> void:
	_dirty_t = Time.get_ticks_msec() / 1000.0


func _save() -> void:
	_dirty_t = -1.0
	if _prop_id.is_empty():
		return
	var main := owner_modal.call("motors_main") as Node
	PlacedPropService.update_prop_record(main, _prop_id, {"csplab_ha": CspLabActuators.normalized(_cfg)}, false)


## Save now (the modal closes).
func flush() -> void:
	if _dirty_t >= 0.0:
		_save()


func config() -> Dictionary:
	return CspLabActuators.normalized(_cfg)


func _on_fill() -> void:
	var nm := str((owner_modal.call("motors_source") as Dictionary).get("name", "concentrator"))
	for i in mini(_last_chans.size(), MAX_EDIT_ROWS):
		var id := str((_last_chans[i] as Dictionary)["id"])
		var cur := str(((_cfg["channels"] as Dictionary).get(id, {}) as Dictionary).get("entity_id", ""))
		if cur.is_empty():
			_set_link(id, "entity_id", CspLabActuators.default_entity(nm, id))
	_rows_key = ""
	refresh()


func _on_yaml() -> void:
	var nm := str((owner_modal.call("motors_source") as Dictionary).get("name", "concentrator"))
	DisplayServer.clipboard_set(CspLabActuators.ha_yaml(nm, _last_chans))
	_status_lbl.text = "Copied: input_number helpers for %d drives and an example automation." % _last_chans.size()
