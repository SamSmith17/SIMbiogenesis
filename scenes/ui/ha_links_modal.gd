extends Node

## Live links — link any Home Assistant entity to any value the simulation
## tracks (HaTargets), for the open world.
##
## Left: every tracked value (the site's energy, the weather station, each
## graph node's fields, tanks), with what it is linked to and its live / sim
## value. Right: the selected value's link (live reading, unit conversion,
## scale / offset, unlink) and the entity browser — your Home Assistant's
## entities, searchable, filtered to the ones that fit the selected value
## (by unit, then device class) unless "Compatible only" is off. Click an
## entity to link it.
##
## Opened by Main.open_ha_links(target_id) from Settings → Home Assistant, the
## inspector's Live twin rows and SolarUI's value labels.

const ENTITY_ROW_LIMIT := 250

var _linker: Node = null
var _svc: Node = null
var _frame: ModalFrame = null
var _sel: String = ""

var _banner: AlertBanner = null
var _target_search: LineEdit = null
var _linked_only: CheckBox = null
var _target_list: VBoxContainer = null
var _target_rows: Dictionary = {}     # target id -> Button
var _left_scroll: ScrollContainer = null
var _right_scroll: ScrollContainer = null

var _sel_title: Label = null
var _sel_values: Label = null
var _link_box: VBoxContainer = null
var _ent_search: LineEdit = null
var _domain_opt: OptionButton = null
var _compat_chk: CheckBox = null
var _ent_list: VBoxContainer = null
var _ent_note: Label = null
var _tick := 0.0
var _link_sig := ""
var _live_btn: Button = null


func open_on(linker: Node, target_id: String = "") -> void:
	_linker = linker
	_svc = get_node_or_null("/root/HomeAssistant")
	if _frame == null:
		_build()
	_frame.open()
	_fit_columns()
	if _svc != null and bool(_svc.call("is_authed")) and int(_svc.call("catalog_size")) == 0:
		_svc.call("refresh_catalog")
	_rebuild_targets()
	if not target_id.is_empty():
		_select(target_id)
	elif _sel.is_empty():
		_select("site.battery_soc")
	else:
		_select(_sel)


func is_open() -> bool:
	return _frame != null and _frame.is_open()


func _build() -> void:
	_frame = ModalFrame.create("Live links", "Link a Home Assistant sensor to any value the simulation tracks. Linked values follow your real system at 1× (Live) and are recorded for comparison at any speed.",
		Vector2(1240, 800), "ha_links")
	add_child(_frame)
	_banner = AlertBanner.new()
	_frame.body.add_child(_banner)
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 14)
	cols.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_frame.body.add_child(cols)

	# ---- left: tracked values ----
	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 470
	left.add_theme_constant_override("separation", 6)
	cols.add_child(left)
	left.add_child(SectionHeader.make("Tracked values", "list"))
	var lrow := HBoxContainer.new()
	lrow.add_theme_constant_override("separation", 6)
	left.add_child(lrow)
	_target_search = LineEdit.new()
	_target_search.placeholder_text = "Find a value…"
	_target_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_target_search.clear_button_enabled = true
	_target_search.text_changed.connect(func(_t: String) -> void: _rebuild_targets())
	lrow.add_child(_target_search)
	_linked_only = CheckBox.new()
	_linked_only.text = "Linked only"
	_linked_only.toggled.connect(func(_on: bool) -> void: _rebuild_targets())
	lrow.add_child(_linked_only)
	_left_scroll = ScrollContainer.new()
	_left_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_left_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_child(_left_scroll)
	_target_list = VBoxContainer.new()
	_target_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_target_list.add_theme_constant_override("separation", 2)
	_left_scroll.add_child(_target_list)

	# ---- right: the selected value + the entity browser ----
	_right_scroll = ScrollContainer.new()
	_right_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_right_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(_right_scroll)
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 6)
	_right_scroll.add_child(right)
	_sel_title = Label.new()
	_sel_title.add_theme_font_override("font", UITheme.font("semibold"))
	_sel_title.add_theme_font_size_override("font_size", UITheme.FONT_MD)
	_sel_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right.add_child(_sel_title)
	_sel_values = Label.new()
	_sel_values.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_sel_values.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_sel_values.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right.add_child(_sel_values)
	_link_box = VBoxContainer.new()
	_link_box.add_theme_constant_override("separation", 6)
	right.add_child(_link_box)

	right.add_child(SectionHeader.make("Your Home Assistant", "house"))
	var erow := HBoxContainer.new()
	erow.add_theme_constant_override("separation", 6)
	right.add_child(erow)
	_ent_search = LineEdit.new()
	_ent_search.placeholder_text = "Search entities by name or id…"
	_ent_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ent_search.clear_button_enabled = true
	_ent_search.text_changed.connect(func(_t: String) -> void: _rebuild_entities())
	erow.add_child(_ent_search)
	_domain_opt = OptionButton.new()
	_domain_opt.fit_to_longest_item = false
	_domain_opt.custom_minimum_size.x = 150
	_domain_opt.item_selected.connect(func(_i: int) -> void: _rebuild_entities())
	erow.add_child(_domain_opt)
	_compat_chk = CheckBox.new()
	_compat_chk.text = "Compatible only"
	_compat_chk.button_pressed = true
	_compat_chk.tooltip_text = "Only entities whose unit (or device class) fits the selected value."
	_compat_chk.toggled.connect(func(_on: bool) -> void: _rebuild_entities())
	erow.add_child(_compat_chk)
	var refresh := IconButton.make("refresh-cw", "Fetch the entity list from Home Assistant again", func() -> void:
		if _svc != null:
			_svc.call("refresh_catalog"))
	erow.add_child(refresh)
	_ent_note = Label.new()
	_ent_note.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_ent_note.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	_ent_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right.add_child(_ent_note)
	_ent_list = VBoxContainer.new()
	_ent_list.add_theme_constant_override("separation", 2)
	right.add_child(_ent_list)

	_live_btn = _frame.add_button("Turn on Live mode", ModalFrame.SECONDARY, _turn_on_live,
		"Live mode runs the clock at real time from now, so linked values follow your real system.")
	_frame.add_button("Presets…", ModalFrame.SECONDARY, _open_presets,
		"Link a known device (an EcoWorthy inverter, a Shelly Pro 4PM…) in one step.")
	_frame.add_button("Home Assistant settings", ModalFrame.SECONDARY, _open_settings)
	_frame.add_button("Done", ModalFrame.PRIMARY, _frame.close)

	if _svc != null:
		_svc.catalog_updated.connect(func() -> void:
			if is_open():
				_rebuild_domains()
				_rebuild_entities())
		_svc.state_changed.connect(func(_s: int, _i: Dictionary) -> void:
			if is_open():
				_refresh_banner())
	if _linker != null and _linker.has_signal("links_changed"):
		_linker.links_changed.connect(func() -> void:
			if is_open():
				_refresh_rows()
				_refresh_selected())
	get_viewport().size_changed.connect(_fit_columns)
	_rebuild_domains()


func _fit_columns() -> void:
	if _left_scroll == null or not is_inside_tree():
		return
	var vp := get_viewport().get_visible_rect().size
	var h := clampf(vp.y - HudLayout.timeline_height() - 260.0, 240.0, 640.0)
	_left_scroll.custom_minimum_size.y = h
	_right_scroll.custom_minimum_size.y = h


func _process(delta: float) -> void:
	if not is_open():
		return
	_tick += delta
	if _tick >= 1.0:
		_tick = 0.0
		_refresh_rows()
		_refresh_selected()
		_refresh_banner()


# ---------------------------------------------------------------------------
# Targets
# ---------------------------------------------------------------------------

func _rebuild_targets() -> void:
	for c in _target_list.get_children():
		_target_list.remove_child(c)
		c.queue_free()
	_target_rows.clear()
	if _linker == null:
		return
	var q := _target_search.text.strip_edges().to_lower()
	var only_linked := _linked_only.button_pressed
	var group := ""
	for t in _linker.call("targets"):
		var tid := str(t["id"])
		var st: Dictionary = _linker.call("link_status", tid)
		if only_linked and not bool(st.get("linked", false)):
			continue
		if not q.is_empty() and not str(t["label"]).to_lower().contains(q) \
				and not str(st.get("entity_id", "")).to_lower().contains(q):
			continue
		if str(t["group"]) != group:
			group = str(t["group"])
			_target_list.add_child(SectionHeader.make(group))
		var b := Button.new()
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		UITheme.style_button(b)
		b.pressed.connect(_select.bind(tid))
		_target_list.add_child(b)
		_target_rows[tid] = b
	_refresh_rows()


func _refresh_rows() -> void:
	if _linker == null:
		return
	for tid in _target_rows.keys():
		var b: Button = _target_rows[tid]
		if not is_instance_valid(b):
			continue
		var t: Dictionary = _linker.call("target", tid)
		var st: Dictionary = _linker.call("link_status", tid)
		var label := str(t.get("label", tid))
		if str(t.get("scope", "")) == "item":
			label = "%s — %s" % [str(t.get("item_label", "")), _field_label(t)]
		var right := ""
		var col := UITheme.C_TEXT
		if bool(st.get("linked", false)):
			if bool(st.get("has_value", false)) and not bool(st.get("stale", true)):
				right = "📡 " + _fmt(float(st["value"]), str(t.get("unit", "")))
				col = UITheme.C_OK
			elif not str(st.get("warn", "")).is_empty():
				right = "⚠ " + _entity_name(str(st["entity_id"]))
				col = UITheme.C_WARN
			else:
				right = "🔗 " + _entity_name(str(st["entity_id"]))
				col = UITheme.C_TEXT_S
		b.text = label if right.is_empty() else "%s     %s" % [label, right]
		b.add_theme_color_override("font_color", col)
		b.button_pressed = tid == _sel
		b.tooltip_text = "%s\n%s" % [str(t.get("label", tid)),
			("Linked to %s" % str(st["entity_id"])) if bool(st.get("linked", false)) else "Not linked — pick an entity on the right."]


func _field_label(t: Dictionary) -> String:
	for f in HaTargets.fields_for_type(str(t.get("item_type", ""))):
		if str(f["field"]) == str(t.get("field", "")):
			return str(f["label"])
	return str(t.get("field", ""))


func _select(tid: String) -> void:
	_sel = tid
	if _linker != null and (_linker.call("target", tid) as Dictionary).is_empty() and not _target_rows.is_empty():
		_sel = str(_target_rows.keys()[0])
	_refresh_rows()
	_refresh_selected()
	_rebuild_entities()
	var b: Variant = _target_rows.get(_sel, null)
	if b is Control and is_instance_valid(b):
		_left_scroll.ensure_control_visible.call_deferred(b)


# ---------------------------------------------------------------------------
# Selected value + its link
# ---------------------------------------------------------------------------

func _refresh_selected() -> void:
	if _linker == null or _sel.is_empty():
		return
	var t: Dictionary = _linker.call("target", _sel)
	var st: Dictionary = _linker.call("link_status", _sel)
	_sel_title.text = str(t.get("label", _sel))
	var unit := str(t.get("unit", ""))
	var sim := float(_linker.call("sim_value", _sel))
	var parts: Array = []
	parts.append("Simulation: %s" % (_fmt(sim, unit) if not is_nan(sim) else "—"))
	if bool(st.get("linked", false)):
		if bool(st.get("has_value", false)):
			var live := float(st["value"])
			var age := int(st.get("age_s", -1))
			parts.append("Home Assistant: %s (%s)" % [_fmt(live, unit), _age(age)])
			if not is_nan(sim) and unit != "bool":
				parts.append("difference %s" % _fmt(live - sim, unit, true))
		else:
			parts.append("Home Assistant: waiting for a reading")
		if bool(st.get("applies", false)):
			parts.append("drives the simulation now (Live mode, 1×)")
		elif not _live_mode_on():
			parts.append("recorded only — Live mode is off")
		else:
			parts.append("recorded only — the clock is not at 1×")
	_sel_values.text = "  ·  ".join(parts)
	var sig := "%s|%s|%s" % [_sel, str(st.get("link", {})), str(st.get("warn", ""))]
	if sig != _link_sig:
		_link_sig = sig
		_rebuild_link_box(t, st)


func _rebuild_link_box(t: Dictionary, st: Dictionary) -> void:
	for c in _link_box.get_children():
		_link_box.remove_child(c)
		c.queue_free()
	if not bool(st.get("linked", false)):
		var l := Label.new()
		l.text = "Not linked. Pick an entity below to link it."
		l.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		_link_box.add_child(l)
		return
	var link: Dictionary = st["link"]
	var eid := str(link["entity_id"])
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_link_box.add_child(row)
	var name_lbl := Label.new()
	name_lbl.text = "🔗 %s  (%s)" % [_entity_name(eid), eid]
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_lbl.tooltip_text = eid
	name_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(name_lbl)
	var en := CheckBox.new()
	en.text = "On"
	en.button_pressed = bool(link.get("enabled", true))
	en.tooltip_text = "Off keeps the link but stops it driving or recording."
	en.toggled.connect(func(on: bool) -> void:
		_linker.call("set_link_fields", str(link["id"]), {"enabled": on}))
	row.add_child(en)
	var un := Button.new()
	un.text = "Unlink"
	UITheme.style_button(un)
	un.add_theme_color_override("font_color", UITheme.C_ERROR)
	un.pressed.connect(func() -> void:
		_linker.call("unlink_target", _sel)
		_link_sig = ""
		_refresh_selected()
		_rebuild_entities())
	row.add_child(un)
	var conv := Label.new()
	var eunit := str((_svc.call("catalog_entry", eid) as Dictionary).get("unit", "")) if _svc != null else ""
	if eunit.is_empty():
		eunit = str(st.get("unit", ""))
	var tunit := str(t.get("unit", ""))
	conv.text = "Unit: %s → %s" % [eunit if not eunit.is_empty() else "none (taken as %s)" % tunit, tunit]
	if not str(st.get("warn", "")).is_empty():
		conv.text += "   ⚠ " + str(st["warn"])
		conv.add_theme_color_override("font_color", UITheme.C_WARN)
	else:
		conv.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	conv.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	conv.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_link_box.add_child(conv)
	if str(t.get("kind", "")) == "numeric":
		var adj := HBoxContainer.new()
		adj.add_theme_constant_override("separation", 8)
		_link_box.add_child(adj)
		adj.add_child(_spin_label("× scale"))
		var sc := SpinBox.new()
		sc.min_value = -1000000.0
		sc.max_value = 1000000.0
		sc.step = 0.0001
		sc.value = float(link.get("scale", 1.0))
		sc.custom_minimum_size.x = 110
		sc.tooltip_text = "Multiply the reading (after the unit conversion). 1 = as is."
		sc.value_changed.connect(func(v: float) -> void:
			_linker.call("set_link_fields", str(link["id"]), {"scale": v}))
		adj.add_child(sc)
		adj.add_child(_spin_label("+ offset"))
		var off := SpinBox.new()
		off.min_value = -1000000.0
		off.max_value = 1000000.0
		off.step = 0.01
		off.value = float(link.get("offset", 0.0))
		off.custom_minimum_size.x = 110
		off.suffix = tunit if tunit != "bool" else ""
		off.value_changed.connect(func(v: float) -> void:
			_linker.call("set_link_fields", str(link["id"]), {"offset": v}))
		adj.add_child(off)
		var inv := CheckBox.new()
		inv.text = "Flip sign"
		inv.button_pressed = bool(link.get("invert", false))
		inv.tooltip_text = "For a battery or grid sensor that counts the other way (discharging positive)."
		inv.toggled.connect(func(on: bool) -> void:
			_linker.call("set_link_fields", str(link["id"]), {"invert": on}))
		adj.add_child(inv)


func _spin_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	return l


# ---------------------------------------------------------------------------
# Entity browser
# ---------------------------------------------------------------------------

func _rebuild_domains() -> void:
	if _domain_opt == null:
		return
	var keep := _domain_opt.get_item_text(_domain_opt.selected) if _domain_opt.selected >= 0 else "All kinds"
	_domain_opt.clear()
	_domain_opt.add_item("All kinds")
	var doms := {}
	if _svc != null:
		for r in _svc.call("catalog"):
			doms[str(r.get("domain", ""))] = true
	var names: Array = doms.keys()
	names.sort()
	for d in names:
		if not str(d).is_empty():
			_domain_opt.add_item(str(d))
	for i in _domain_opt.item_count:
		if _domain_opt.get_item_text(i) == keep:
			_domain_opt.select(i)


func _rebuild_entities() -> void:
	for c in _ent_list.get_children():
		_ent_list.remove_child(c)
		c.queue_free()
	if _svc == null or _linker == null:
		return
	if not bool(_svc.call("is_authed")):
		_ent_note.text = "Not connected to Home Assistant. Connect in Home Assistant settings to browse your entities."
		return
	var rows: Array = _svc.call("catalog")
	if rows.is_empty():
		_ent_note.text = "Loading the entity list…"
		return
	var t: Dictionary = _linker.call("target", _sel)
	var tunit := str(t.get("unit", ""))
	var tkind := str(t.get("kind", "numeric"))
	var q := _ent_search.text.strip_edges().to_lower()
	var dom := _domain_opt.get_item_text(_domain_opt.selected) if _domain_opt.selected > 0 else ""
	var compat_only := _compat_chk.button_pressed
	var linked_eid := str((_linker.call("link_status", _sel) as Dictionary).get("entity_id", ""))
	var scored: Array = []
	for r in rows:
		if not dom.is_empty() and str(r.get("domain", "")) != dom:
			continue
		if not q.is_empty() and not str(r.get("name", "")).to_lower().contains(q) \
				and not str(r.get("entity_id", "")).to_lower().contains(q):
			continue
		var sc := HaUnits.compatibility(tunit, tkind, r)
		if compat_only and sc < 0.5 and str(r.get("entity_id", "")) != linked_eid:
			continue
		scored.append([sc + _name_hint(t, r), r])
	scored.sort_custom(func(a, b):
		if absf(float(a[0]) - float(b[0])) > 0.001:
			return float(a[0]) > float(b[0])
		return str(a[1].get("name", "")) < str(b[1].get("name", "")))
	var shown := 0
	for pair in scored:
		if shown >= ENTITY_ROW_LIMIT:
			break
		var r: Dictionary = pair[1]
		var eid := str(r.get("entity_id", ""))
		var b := Button.new()
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.focus_mode = Control.FOCUS_NONE
		UITheme.style_button(b)
		var val := str(r.get("state", ""))
		if not str(r.get("unit", "")).is_empty():
			val += " " + str(r["unit"])
		b.text = "%s     %s     %s" % [str(r.get("name", eid)), val, eid]
		b.tooltip_text = "%s\n%s\nstate: %s%s\nClick to link it to: %s" % [str(r.get("name", eid)), eid, val,
			("\ndevice class: " + str(r["device_class"])) if not str(r.get("device_class", "")).is_empty() else "",
			str(t.get("label", _sel))]
		if eid == linked_eid:
			b.add_theme_color_override("font_color", UITheme.C_OK)
			b.text = "✓ " + b.text
		b.pressed.connect(_link_entity.bind(eid))
		_ent_list.add_child(b)
		shown += 1
	var total := scored.size()
	_ent_note.text = ("%s%s" % [UiText.count(total, "match", "matches"),
		(" (showing %d — search to narrow)" % ENTITY_ROW_LIMIT) if total > ENTITY_ROW_LIMIT else ""]) \
		+ ("" if not compat_only else "  ·  only entities whose unit fits %s" % (tunit if tunit != "bool" else "on / off"))


## A small bonus for entities whose name matches the value's own words
## ("battery" for a state of charge, "solar" / "pv" for solar…).
func _name_hint(t: Dictionary, r: Dictionary) -> float:
	var n := (str(r.get("name", "")) + " " + str(r.get("entity_id", ""))).to_lower()
	var words: Array = []
	match str(t.get("field", "")):
		"battery_soc", "soc": words = ["battery", "soc", "charge"]
		"solar_kw", "daily_solar_kwh": words = ["solar", "pv"]
		"load_kw": words = ["load", "consumption", "output"]
		"temp_c": words = ["outdoor", "outside", "temperature"]
		"wind_ms": words = ["wind"]
		"irradiance": words = ["radiation", "solar", "irradiance"]
		"rain_rate", "raining": words = ["rain"]
	var item_name := str(t.get("item_label", "")).to_lower()
	if not item_name.is_empty() and n.contains(item_name):
		return 0.3
	for w in words:
		if n.contains(w):
			return 0.2
	return 0.0


func _link_entity(eid: String) -> void:
	if _linker == null or _sel.is_empty():
		return
	_linker.call("link_entity", eid, _sel)
	_link_sig = ""
	_refresh_rows()
	_refresh_selected()
	_rebuild_entities()


# ---------------------------------------------------------------------------
# Footer + status
# ---------------------------------------------------------------------------

func _live_mode_on() -> bool:
	var ssc := get_node_or_null("/root/SimSettingsController")
	return ssc != null and bool(ssc.get("live_mode_enabled"))


func _turn_on_live() -> void:
	var ssc := get_node_or_null("/root/SimSettingsController")
	if ssc != null and ssc.has_method("set_live_mode"):
		ssc.call("set_live_mode", true)
	_refresh_banner()


func _refresh_banner() -> void:
	if _svc == null:
		_banner.show_alert(AlertBanner.ERROR, "The Home Assistant service is missing.")
		return
	var live_on := _live_mode_on()
	if _live_btn != null:
		_live_btn.visible = not live_on
	if bool(_svc.call("is_authed")) and not live_on:
		_banner.show_alert(AlertBanner.WARN, "%s  ·  Live mode is off, so links only record readings. Turn on Live mode to make linked values follow your real system." % str(_svc.call("status_text")))
	elif bool(_svc.call("is_authed")):
		var txt := str(_svc.call("links_summary_text"))
		_banner.show_alert(AlertBanner.OK, "%s%s" % [str(_svc.call("status_text")), ("  ·  " + txt) if not txt.is_empty() else ""])
	else:
		_banner.show_alert(AlertBanner.WARN, "%s — links are kept, and start working when Home Assistant connects." % str(_svc.call("status_text")))


func _open_settings() -> void:
	var main := get_tree().current_scene
	_frame.close()
	if main != null and main.has_method("open_settings_page"):
		main.call("open_settings_page", "Home Assistant")


func _open_presets() -> void:
	var main := get_tree().current_scene
	if main != null and main.has_method("open_ha_presets"):
		main.call("open_ha_presets", _sel)


func _entity_name(eid: String) -> String:
	if _svc == null:
		return eid
	var r: Dictionary = _svc.call("catalog_entry", eid)
	return str(r.get("name", eid)) if not r.is_empty() else eid


static func _fmt(v: float, unit: String, signed := false) -> String:
	if unit == "bool":
		return "on" if v >= 0.5 else "off"
	var a := absf(v)
	var s := ("%.0f" if a >= 100.0 else ("%.1f" if a >= 10.0 else "%.2f")) % v
	if signed and v > 0.0:
		s = "+" + s
	return "%s %s" % [s, unit] if not unit.is_empty() else s


static func _age(s: int) -> String:
	if s < 0:
		return "no reading"
	if s < 5:
		return "now"
	if s < 120:
		return "%d s ago" % s
	if s < 7200:
		return "%d min ago" % (s / 60)
	return "%d h ago" % (s / 3600)
