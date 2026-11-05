class_name GraphFestivalBoard
extends VBoxContainer
## The Festival board (plans/GRAPH_SYSTEMS_UX_PLAN.md Phase 3): one row per
## power system with people · battery · AC · water days · food days · what
## is wrong, sortable and filterable; a click flies to the system, a
## double-click goes inside. The same widget sits in the dashboard's Board tab
## (narrow) and in the full-screen board over the canvas (wide).
##
## It never walks the model: it reads SystemGraphView.system_board_rows(),
## rebuilt once a second, and rebuilds its rows only when what they show
## changes (a blind rebuild drops a hover and eats a double-click).

signal expand_pressed

const ROW_LIMIT := 80
const LEVEL_COLORS := {"idle": Color(0.45, 0.50, 0.58), "ok": Color(0.36, 0.80, 0.50),
	"warn": Color(0.96, 0.66, 0.25), "crit": Color(0.93, 0.33, 0.30)}

var wide := false
var _view: Node = null
var _filter := "all"
var _sort := "attention"
var _desc := true
var _sig := "<unset>"
var _rows_box: VBoxContainer = null
var _count_lbl: Label = null
var _filter_btns: Dictionary = {}
var _sort_btns: Dictionary = {}
var _expand_btn: Button = null
var _last_click_id := ""
var _last_click_ms := 0


func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 6)
	_build()


func bind(view: Node) -> void:
	_view = view
	refresh()


func set_filter(f: String) -> void:
	_filter = f if f in GraphSystemBoard.FILTERS else "all"
	_sync_buttons()
	refresh()


func set_sort(key: String, descending: bool) -> void:
	_sort = key
	_desc = descending
	_sync_buttons()
	refresh()


func current_filter() -> String:
	return _filter


func _build() -> void:
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	add_child(head)
	_count_lbl = Label.new()
	_count_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_count_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM if wide else UITheme.FONT_XS)
	_count_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_count_lbl.clip_text = true
	head.add_child(_count_lbl)
	_expand_btn = Button.new()
	_expand_btn.name = "BoardExpand"
	UiIcons.apply(_expand_btn, "minimize-2" if wide else "maximize-2",
		"Close the full-screen board (Esc)" if wide else "Open the board full screen")
	UITheme.style_button(_expand_btn)
	_expand_btn.pressed.connect(func() -> void: expand_pressed.emit())
	head.add_child(_expand_btn)

	var chips := HFlowContainer.new()
	chips.add_theme_constant_override("h_separation", 4)
	chips.add_theme_constant_override("v_separation", 4)
	add_child(chips)
	for f: String in GraphSystemBoard.FILTERS:
		var b := Button.new()
		b.name = "Filter_" + f
		b.text = str(GraphSystemBoard.FILTER_LABELS[f])
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(set_filter.bind(f))
		chips.add_child(b)
		_filter_btns[f] = b

	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", _gap())
	add_child(cols)
	for key: String in GraphSystemBoard.SORTS:
		if key == "attention":
			continue
		var b := Button.new()
		b.name = "Sort_" + key
		b.flat = true
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		b.clip_text = true
		b.tooltip_text = "Sort by %s (click again to reverse; a third time sorts by attention)" \
			% str(GraphSystemBoard.SORT_LABELS[key]).to_lower()
		if key == "name":
			b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		else:
			b.custom_minimum_size = Vector2(_col_w(key), 0)
			b.alignment = HORIZONTAL_ALIGNMENT_RIGHT
		b.add_theme_constant_override("h_separation", 0)
		var pad := StyleBoxEmpty.new()
		for side in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
			b.add_theme_stylebox_override(side, pad)
		b.pressed.connect(_on_sort_pressed.bind(key))
		cols.add_child(b)
		_sort_btns[key] = b
	if wide:
		var why := Label.new()
		why.text = "What is wrong"
		why.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		why.size_flags_stretch_ratio = 1.6
		why.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		why.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		why.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		cols.add_child(why)

	_rows_box = VBoxContainer.new()
	_rows_box.add_theme_constant_override("separation", 1)
	if wide:
		var sc := ScrollContainer.new()
		sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
		sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sc.add_child(_rows_box)
		add_child(sc)
	else:
		add_child(_rows_box)
	_sync_buttons()


func _gap() -> int:
	return 14 if wide else 2


func _col_w(key: String) -> float:
	match key:
		"people":
			return 70.0 if wide else 34.0
		"soc":
			return 74.0 if wide else 40.0
		"water", "food":
			return 84.0 if wide else 46.0
		"ac":
			return 44.0
		"reasons":
			return 280.0
	return 60.0


func _on_sort_pressed(key: String) -> void:
	if _sort != key:
		# Worst first for every numeric column; names A to Z.
		set_sort(key, key != "name" and key != "soc" and key != "water" and key != "food")
	elif (key == "name") == (not _desc):
		set_sort(key, not _desc)
	else:
		set_sort("attention", true)


func _sync_buttons() -> void:
	for f: String in _filter_btns.keys():
		var b: Button = _filter_btns[f]
		b.set_pressed_no_signal(f == _filter)
		UITheme.style_toggle(b, f == _filter, UITheme.FONT_XS)
	for key: String in _sort_btns.keys():
		var b: Button = _sort_btns[key]
		var arrow := ""
		if key == _sort:
			arrow = " ▼" if _desc else " ▲"
		b.text = _col_title(key) + arrow
		b.add_theme_color_override("font_color", UITheme.C_PRIMARY if key == _sort else UITheme.C_TEXT_M)


func _col_title(key: String) -> String:
	if wide:
		return str(GraphSystemBoard.SORT_LABELS[key])
	match key:
		"people":
			return "👥"
		"soc":
			return "🔋"
		"water":
			return "💧"
		"food":
			return "🍎"
	return str(GraphSystemBoard.SORT_LABELS[key])


func _process(_dt: float) -> void:
	if is_visible_in_tree():
		refresh()


func refresh() -> void:
	if _view == null or not is_instance_valid(_view) or _rows_box == null:
		return
	var all: Array = _view.call("system_board_rows")
	var rows := GraphSystemBoard.filtered(all, _filter)
	rows = GraphSystemBoard.sorted(rows, _sort, _desc)
	var parts := PackedStringArray([_filter, _sort, str(_desc), str(all.size())])
	for r: Dictionary in rows:
		parts.append("%s|%s|%s|%d|%.2f|%s|%s|%s" % [r["id"], r["name"], r["level"], int(r["people"]),
			float(r["soc"]), _days(float(r["water_days"]), bool(r["has_water"])),
			_days(float(r["food_days"]), bool(r["has_food"])), ",".join(PackedStringArray(r["reasons"]))])
	var sig := "\n".join(parts)
	if sig == _sig:
		return
	_sig = sig
	var t := GraphSystemBoard.totals(all)
	var shown := "%s · %d need attention" % [UiText.count(int(t["systems"]), "system"),
		int(t["crit"]) + int(t["warn"])]
	if int(t["people"]) > 0:
		shown += " · " + UiText.count(int(t["people"]), "person", "people")
	_count_lbl.text = shown
	var restore := UITheme.keep_scroll(_rows_box)
	for c in _rows_box.get_children():
		_rows_box.remove_child(c)
		c.free()
	if rows.is_empty():
		var empty := Label.new()
		empty.text = "Nothing needs attention." if _filter == "attention" else "No systems to list."
		empty.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		empty.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		_rows_box.add_child(empty)
		return
	for i in mini(rows.size(), ROW_LIMIT):
		_rows_box.add_child(_make_row(rows[i] as Dictionary))
	if rows.size() > ROW_LIMIT:
		var more := Label.new()
		more.text = "+%d more (filter to narrow the list)" % (rows.size() - ROW_LIMIT)
		more.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		more.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		_rows_box.add_child(more)
	restore.call()


static func _days(d: float, has: bool) -> String:
	if not has:
		return "—"
	if not is_finite(d):
		return "∞"
	if d < 1.0:
		return "%d h" % int(round(d * 24.0))
	return "%.1f d" % d


func _make_row(r: Dictionary) -> Control:
	var btn := Button.new()
	btn.name = "Row_" + str(r["id"]) if not str(r["id"]).is_empty() else "Row_site"
	btn.set_meta("system_id", str(r["id"]))
	btn.flat = true
	btn.focus_mode = Control.FOCUS_NONE
	btn.custom_minimum_size = Vector2(0, 34 if (not wide and not (r["reasons"] as Array).is_empty()) else 24)
	btn.tooltip_text = _tooltip(r)
	btn.pressed.connect(_on_row_pressed.bind(str(r["id"])))
	var lvl := str(r["level"])
	var hover := StyleBoxFlat.new()
	hover.bg_color = Color(UITheme.C_PRIMARY, 0.10)
	hover.set_corner_radius_all(4)
	btn.add_theme_stylebox_override("hover", hover)
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(LEVEL_COLORS[lvl], 0.08) if lvl in ["warn", "crit"] else Color(0, 0, 0, 0)
	normal.set_corner_radius_all(4)
	normal.border_width_left = 3
	normal.border_color = LEVEL_COLORS[lvl]
	btn.add_theme_stylebox_override("normal", normal)
	var hb := HBoxContainer.new()
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_theme_constant_override("separation", _gap())
	hb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hb.offset_left = 7.0
	btn.add_child(hb)
	var name_col := VBoxContainer.new()
	name_col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_col.alignment = BoxContainer.ALIGNMENT_CENTER
	name_col.add_theme_constant_override("separation", -2)
	hb.add_child(name_col)
	var icon := "⛺ " if str(r["kind"]) == GraphSystems.KIND_CAMP else \
		("🚐 " if str(r["kind"]) == GraphSystems.KIND_VEHICLE else "🏠 ")
	name_col.add_child(_cell(icon + str(r["name"]), -1.0, UITheme.C_TEXT, UITheme.FONT_SM if wide else UITheme.FONT_XS))
	if not wide and not (r["reasons"] as Array).is_empty():
		name_col.add_child(_cell(", ".join(PackedStringArray(r["reasons"])), -1.0, LEVEL_COLORS[lvl], 10))
	var fs := UITheme.FONT_SM if wide else UITheme.FONT_XS
	hb.add_child(_cell(str(int(r["people"])) if int(r["people"]) >= 0 else "—", _col_w("people"), UITheme.C_TEXT_S, fs, true))
	var soc := float(r["soc"])
	var soc_txt := "—" if soc < 0.0 else "%d%%" % int(round(soc * 100.0))
	if not bool(r["ac"]):
		soc_txt = "off" if soc < 0.0 else soc_txt + "!"
	hb.add_child(_cell(soc_txt, _col_w("soc"),
		LEVEL_COLORS["crit"] if not bool(r["ac"]) else (LEVEL_COLORS["warn"] if soc >= 0.0 and soc < GraphSystemBoard.SOC_WARN else UITheme.C_TEXT_S), fs, true))
	for pair: Array in [["water_days", "has_water"], ["food_days", "has_food"]]:
		var d := float(r[pair[0]])
		var col := UITheme.C_TEXT_S
		if bool(r[pair[1]]) and d < GraphSystemBoard.DAYS_CRIT:
			col = LEVEL_COLORS["crit"]
		elif bool(r[pair[1]]) and d < GraphSystemBoard.DAYS_WARN:
			col = LEVEL_COLORS["warn"]
		hb.add_child(_cell(_days(d, bool(r[pair[1]])), _col_w("water"), col, fs, true))
	if wide:
		hb.add_child(_cell(", ".join(PackedStringArray(r["reasons"])) if not (r["reasons"] as Array).is_empty() else "fine",
			-1.0, LEVEL_COLORS[lvl] if lvl in ["warn", "crit"] else UITheme.C_TEXT_M, fs))
		(hb.get_child(hb.get_child_count() - 1) as Control).size_flags_stretch_ratio = 1.6
	return btn


func _cell(text: String, w: float, col: Color, fs: int, right: bool = false) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.clip_text = true
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if right:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	if w > 0.0:
		l.custom_minimum_size = Vector2(w, 0)
	else:
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.add_theme_font_size_override("font_size", fs)
	l.add_theme_color_override("font_color", col)
	return l


func _tooltip(r: Dictionary) -> String:
	var lines := PackedStringArray([str(r["name"])])
	if float(r["cap_kwh"]) > 0.0:
		lines.append("Battery %.1f / %.1f kWh · solar %.2f kW · load %.2f kW" % [
			float(r["kwh"]), float(r["cap_kwh"]), float(r["pv_kw"]), float(r["load_kw"])])
	if not bool(r["ac"]):
		lines.append("Its loads are switched off: the battery is empty.")
	for s: Dictionary in (r["stores"] as Array):
		lines.append("%s: %.0f / %.0f %s, %s" % [ResourceKinds.display_name(str(s["kind"])),
			float(s["stock"]), float(s["capacity"]), str(s["unit"]), GraphSystemBoard.fmt_days(float(s["days"]))])
	if not (r["reasons"] as Array).is_empty():
		lines.append("Needs: " + ", ".join(PackedStringArray(r["reasons"])))
	lines.append("Click to fly there · double-click to go inside")
	return "\n".join(lines)


func _on_row_pressed(id: String) -> void:
	if _view == null:
		return
	var now := Time.get_ticks_msec()
	var dbl := id == _last_click_id and now - _last_click_ms < 450
	_last_click_id = id
	_last_click_ms = now
	_view.call("board_fly_to", id, dbl)
