extends Control

## The ESP board designer: pick a board, add sensors / actuators / breakouts,
## and the tool wires them to the right pins by protocol (I²C, SPI, UART,
## 1-Wire, analog, PWM, plain GPIO) and writes the ESPHome YAML.
## Plan: ~/.claude/plans/take-a-look-at-shimmering-fountain.md (Phase 3).
##
## Left:   the board, the parts palette by category (click to add), the
##         parts on this board, designs to start from (built-ins + library).
## Centre: the wiring diagram (EspDiagram) or the YAML.
## Right:  the selection's card (a part, or a board pin), the checks, the
##         power budget, the Home Assistant entities it makes, parts list.
##
## Every edit goes through _set_spec (undoable); the design is re-solved by
## EspDesign (cached on the spec's key, which leaves the card layout out).

const MODAL_NAME := "esplab_designer"
const WANT := Vector2(1640, 980)
const UNDO_LIMIT := 80
const EXPORT_DIR := "user://esplab_designs"
const Diagram := preload("res://scenes/ui/esplab_diagram.gd")
const CompareChart := preload("res://scenes/ui/esplab_compare_chart.gd")

var _active := false
var _spec: Dictionary = {}
var _design: Dictionary = {}
var _undo: Array = []
var _redo: Array = []
var _sel: Dictionary = {}           # {kind: part|pin, iid | gpio}
var _tab := "diagram"
var _library: Array = []
var _bound_prop_id := ""
var _part_filter := ""
var _probe: EspWorldProbe = null
var _live := {}                     # entity_id -> {text, value, available}
var _live_acc := 0.0
var _ent_vals := {}                 # entity_id -> Label (the value column)

var _shell: DesignerShell
var _diagram: Control
var _yaml_view: CodeEdit
var _tab_btns: Dictionary = {}
var _hover_lbl: Label
var _board_opt: OptionButton
var _board_note: Label
var _palette: VBoxContainer
var _in_use: VBoxContainer
var _designs_box: VBoxContainer
var _card: VBoxContainer
var _checks_box: VBoxContainer
var _power_lbl: Label
var _col: DesignerColumn
var _ents_box: VBoxContainer
var _bom_box: VBoxContainer
var _status: Label
var _place_btn: Button
var _cmp: VBoxContainer
var _cmp_rows: VBoxContainer
var _cmp_status: Label
var _cmp_span: OptionButton
var _cmp_results := {}
var _cmp_running := false
var _apply_btn: Button


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	set_process_input(false)
	set_process(false)


# ---------------------------------------------------------------------------
# Open / close / API (the harness drives these)
# ---------------------------------------------------------------------------

## opts: {spec}
func open(opts: Dictionary = {}) -> void:
	if _active:
		return
	var spec: Dictionary = opts.get("spec", {})
	_bound_prop_id = str(opts.get("prop_id", ""))
	if not _bound_prop_id.is_empty():
		var rec := PlacedPropService.get_prop_record(_main(), _bound_prop_id)
		if rec.is_empty():
			_bound_prop_id = ""
		elif rec.get("esp_spec") is Dictionary:
			spec = (rec["esp_spec"] as Dictionary).duplicate(true)
	if spec.is_empty():
		spec = EspPresets.builtin("weather_station")
	_undo.clear()
	_redo.clear()
	_sel = {}
	_library = EspPresets.load_library()
	_active = true
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process_input(true)
	set_process(true)
	_make_probe()
	_shell.open()
	_set_spec(spec, false)
	_refresh_designs()
	_set_tab("diagram")
	_set_status("")
	_apply_btn.visible = not _bound_prop_id.is_empty()
	_place_btn.text = "Place a copy" if not _bound_prop_id.is_empty() else "Place in world"
	_fit_later()


func _main() -> Node:
	return get_tree().current_scene if get_tree() != null else null


func bound_prop_id() -> String:
	return _bound_prop_id


func close() -> void:
	if not _active:
		return
	_active = false
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process_input(false)
	set_process(false)
	_shell.close()


func is_open() -> bool:
	return _active


func spec() -> Dictionary:
	return _spec


func design() -> Dictionary:
	return _design


func diagram() -> Control:
	return _diagram


func yaml_text() -> String:
	return str(_design.get("yaml", ""))


func selected() -> Dictionary:
	return _sel


## The twin's latest readings: entity_id -> {text, value, available}.
func live_readings() -> Dictionary:
	return _live


func probe() -> EspWorldProbe:
	return _probe


func status_text() -> String:
	return _status.text if _status != null else ""


func load_builtin(id: String) -> void:
	var s := EspPresets.builtin(id)
	if not s.is_empty():
		_sel = {}
		_set_spec(s)
		_fit_later()


func add_part(part_id: String) -> String:
	var s := EspSpec.with_part(_spec, part_id)
	var iid := str((s["parts"] as Array).back()["iid"])
	_set_spec(s)
	_select({"kind": "part", "iid": iid})
	return iid


func remove_part(iid: String) -> void:
	_sel = {}
	_set_spec(EspSpec.without_part(_spec, iid))


func set_board(board_id: String) -> void:
	if not EspBoards.BOARDS.has(board_id) or board_id == str(_spec.get("board", "")):
		return
	var s := _spec.duplicate(true)
	s["board"] = board_id
	# Pins dragged by hand belong to the old board.
	s["locks"] = {}
	s.erase("layout")
	_sel = {}
	_set_spec(s)
	_fit_later()


# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	_shell = DesignerShell.create("ESP board designer", "cpu", {
		"name_id": MODAL_NAME, "want": WANT, "name_edit": true, "undo": true,
		"left_label": "Board & parts", "left_w": 260.0, "right_w": 390.0})
	add_child(_shell)
	_shell.undo_requested.connect(_undo_step)
	_shell.redo_requested.connect(_redo_step)
	_shell.name_submitted.connect(_on_name_submitted)
	_shell.closed.connect(close)
	_build_left()
	_build_centre()
	_build_right()
	_shell.add_button("Save design", DesignerShell.SECONDARY, _on_save_design,
		"Keep this design in your library (by its name)")
	_shell.add_button("Export files", DesignerShell.SECONDARY, _on_export,
		"Write the ESPHome YAML, a secrets.yaml template, the wiring diagram (PNG) and the design (JSON)")
	var copy := _shell.add_button("Copy YAML", DesignerShell.SECONDARY, _on_copy_yaml,
		"Copy the ESPHome YAML to the clipboard, ready to paste into the ESPHome dashboard")
	copy.name = "copy_yaml"
	_apply_btn = _shell.add_button("Apply to placed board", DesignerShell.SECONDARY, _on_apply,
		"Rebuild the placed board as this design (its twin and graph node follow)")
	_apply_btn.name = "apply_placed"
	_place_btn = _shell.add_button("Place in world", DesignerShell.PRIMARY, _on_place,
		"Put this board on the map on a stake: its twin reads the world where it stands")
	_place_btn.name = "place_world"
	_shell.add_button("Close", DesignerShell.SECONDARY, close)
	_shell.set_hint("Click a part to add it · drag a part's pin onto a board pin to wire it yourself · double-click a wire to give it back · wheel zooms")


func _caption(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	l.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	return l


func _build_left() -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	_shell.left.add_child(box)
	box.add_child(SectionHeader.make("Board", "cpu"))
	_board_opt = OptionButton.new()
	_board_opt.name = "board_pick"
	_board_opt.fit_to_longest_item = false
	_board_opt.clip_text = true
	_board_opt.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var by_chip := {}
	for id in EspBoards.ids():
		var c := str(EspBoards.get_board(id)["chip"])
		if not by_chip.has(c):
			by_chip[c] = []
		(by_chip[c] as Array).append(id)
	for c in EspChips.ALL:
		if not by_chip.has(c):
			continue
		_board_opt.add_separator(str(EspChips.get_chip(c)["label"]))
		for id in by_chip[c]:
			_board_opt.add_item(str(EspBoards.get_board(id)["label"]))
			_board_opt.set_item_metadata(_board_opt.item_count - 1, id)
	_board_opt.item_selected.connect(func(i: int) -> void: set_board(str(_board_opt.get_item_metadata(i))))
	box.add_child(_board_opt)
	_board_note = _caption("")
	box.add_child(_board_note)
	# Adding parts is a mode: the 60 parts open from the strip's "Add part"
	# button; this column is the board, what is on it and the designs.
	var adder := VBoxContainer.new()
	adder.name = "adder"
	adder.add_theme_constant_override("separation", 4)
	var search := LineEdit.new()
	search.name = "part_search"
	search.placeholder_text = "Search parts (BME280, CO2, relay…)"
	search.clear_button_enabled = true
	search.text_changed.connect(func(t: String) -> void:
		_part_filter = t.strip_edges().to_lower()
		_refresh_palette())
	adder.add_child(search)
	_palette = VBoxContainer.new()
	_palette.name = "palette"
	_palette.add_theme_constant_override("separation", 2)
	adder.add_child(_palette)
	_shell.add_flyout_button("add", "Add part", "plus", adder, {"width": 320.0,
		"tip": "Sensors, relays, screens… click one to put it on the board"})
	box.add_child(SectionHeader.make("On this board", "list"))
	_in_use = VBoxContainer.new()
	_in_use.name = "in_use"
	_in_use.add_theme_constant_override("separation", 2)
	box.add_child(_in_use)
	box.add_child(SectionHeader.make("Start from", "layout-grid"))
	_designs_box = VBoxContainer.new()
	_designs_box.name = "designs"
	_designs_box.add_theme_constant_override("separation", 2)
	box.add_child(_designs_box)
	_refresh_palette()


func _build_centre() -> void:
	var strip := HBoxContainer.new()
	strip.add_theme_constant_override("separation", 4)
	_shell.centre.add_child(strip)
	for t in [["diagram", "Wiring", "The circuit: board, parts and every wire"], ["yaml", "ESPHome YAML", "The config this wiring makes"],
			["compare", "Compare", "Lay the twin over your real board's history from Home Assistant"]]:
		var b := Button.new()
		b.name = "tab_%s" % str(t[0])
		b.text = str(t[1])
		b.tooltip_text = str(t[2])
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		UITheme.style_button(b)
		b.pressed.connect(_set_tab.bind(str(t[0])))
		strip.add_child(b)
		_tab_btns[str(t[0])] = b
	var fit := Button.new()
	fit.name = "fit"
	fit.text = "Fit"
	fit.tooltip_text = "Fit the diagram to the view (F)"
	fit.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(fit)
	fit.pressed.connect(func() -> void: _diagram.call("fit"))
	strip.add_child(fit)
	var rewire := Button.new()
	rewire.name = "rewire_all"
	rewire.text = "Re-wire all"
	rewire.tooltip_text = "Forget every wire you placed by hand and let the tool wire the whole board"
	rewire.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(rewire)
	rewire.pressed.connect(_on_rewire_all)
	strip.add_child(rewire)
	_hover_lbl = Label.new()
	_hover_lbl.name = "hover"
	_hover_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hover_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_hover_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_hover_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	strip.add_child(_hover_lbl)
	_diagram = Diagram.new()
	_diagram.name = "Diagram"
	_diagram.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_shell.centre.add_child(_diagram)
	_diagram.connect("part_clicked", func(iid: String) -> void: _select({"kind": "part", "iid": iid}))
	_diagram.connect("board_pin_clicked", func(g: int, _l: String) -> void:
		if g >= 0:
			_select({"kind": "pin", "gpio": g}))
	_diagram.connect("empty_clicked", func() -> void: _select({}))
	_diagram.connect("part_moved", _on_part_moved)
	_diagram.connect("wire_drawn", _on_wire_drawn)
	_diagram.connect("wire_removed", _on_wire_removed)
	_diagram.connect("hover_changed", func(t: String) -> void: _hover_lbl.text = t)
	_yaml_view = CodeEdit.new()
	_yaml_view.name = "YamlView"
	_yaml_view.editable = false
	_yaml_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_yaml_view.gutters_draw_line_numbers = true
	_yaml_view.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	var hl := CodeHighlighter.new()
	hl.number_color = Color(0.7, 0.85, 1.0)
	hl.symbol_color = UITheme.C_TEXT_S
	hl.member_variable_color = UITheme.C_PRIMARY
	hl.add_color_region("#", "", UITheme.C_TEXT_M, true)
	hl.add_color_region("\"", "\"", UITheme.C_GOLD)
	hl.add_color_region("!", " ", UITheme.C_LAVENDER)
	_yaml_view.syntax_highlighter = hl
	_yaml_view.visible = false
	_shell.centre.add_child(_yaml_view)
	_build_compare()


func _build_right() -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	_shell.right.add_child(box)
	_card = VBoxContainer.new()
	_card.name = "card"
	_card.add_theme_constant_override("separation", 4)
	box.add_child(_card)
	box.add_child(SectionHeader.make("Checks", "circle-check"))
	_checks_box = VBoxContainer.new()
	_checks_box.name = "checks"
	_checks_box.add_theme_constant_override("separation", 3)
	box.add_child(_checks_box)
	box.add_child(SectionHeader.make("Power", "zap"))
	_power_lbl = Label.new()
	_power_lbl.name = "power"
	_power_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_power_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	box.add_child(_power_lbl)
	box.add_child(SectionHeader.make("In Home Assistant", "house", "what the board will report"))
	_ents_box = VBoxContainer.new()
	_ents_box.name = "entities"
	_ents_box.add_theme_constant_override("separation", 1)
	box.add_child(_ents_box)
	box.add_child(SectionHeader.make("Parts list", "list"))
	_bom_box = VBoxContainer.new()
	_bom_box.add_theme_constant_override("separation", 1)
	box.add_child(_bom_box)
	_status = Label.new()
	_status.name = "status"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_status.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	box.add_child(_status)
	_col = DesignerColumn.setup(box, "esplab", {"fold": ["In Home Assistant", "Parts list"], "finder": false})


# ---------------------------------------------------------------------------
# Spec, undo, refresh
# ---------------------------------------------------------------------------

func _set_spec(s: Dictionary, push: bool = true) -> void:
	if push and not _spec.is_empty():
		_undo.append(_spec.duplicate(true))
		if _undo.size() > UNDO_LIMIT:
			_undo.pop_front()
		_redo.clear()
	_spec = EspSpec.resolve(s)
	_design = EspDesign.solve(_spec)
	if not _sel_exists():
		_sel = {}
	_shell.set_undo_state(not _undo.is_empty(), not _redo.is_empty())
	_refresh_all()


func _sel_exists() -> bool:
	match str(_sel.get("kind", "")):
		"part":
			for p in _spec["parts"]:
				if str(p["iid"]) == str(_sel["iid"]):
					return true
			return false
		"pin":
			return EspBoards.header_gpios(_design["board"]).has(int(_sel["gpio"]))
	return false


func _undo_step() -> void:
	if _undo.is_empty():
		return
	_redo.append(_spec.duplicate(true))
	_set_spec(_undo.pop_back(), false)


func _redo_step() -> void:
	if _redo.is_empty():
		return
	_undo.append(_spec.duplicate(true))
	_set_spec(_redo.pop_back(), false)


func _refresh_all() -> void:
	if _shell.name_edit != null and not _shell.name_edit.has_focus():
		_shell.name_edit.text = str(_spec["name"])
	_shell.set_subtitle("%s · %s · node %s" % [_design["board_label"], str(EspChips.get_chip(str(_design["chip"]))["label"]), _design["node"]])
	_sync_board_pick()
	_refresh_in_use()
	_diagram.call("set_design", _design, _spec)
	_diagram.call("set_readings", _readings())
	_sync_diagram_selection()
	_yaml_view.text = str(_design["yaml"])
	_refresh_card()
	_refresh_checks()
	_refresh_power()
	_refresh_entities()
	_refresh_bom()
	_live_acc = 1.0


## Each card's lines: what the twin reads now, or what it will report.
func _readings() -> Dictionary:
	var out := {}
	for e in _design["entities"]:
		var iid := str(e["iid"])
		if iid == "":
			continue
		var lv: Dictionary = _live.get(str(e["entity_id"]), {})
		var txt := str(lv.get("text", "")) if not lv.is_empty() else ("· " + str(e["unit"]) if str(e["unit"]) != "" else "")
		# A PackedStringArray in a Dictionary is a copy: append, then put back.
		var lines: PackedStringArray = out.get(iid, PackedStringArray())
		lines.append("%s  %s" % [e["short"], txt])
		out[iid] = lines
	return out


# ---------------------------------------------------------------------------
# The twin, live
# ---------------------------------------------------------------------------

## The world at the site: the player's spot when there is one, else the
## world origin (the site centre on a generated map).
func _make_probe() -> void:
	var main := get_tree().current_scene if get_tree() != null else null
	var pos := Vector3.ZERO
	if main != null:
		var pl := main.get_node_or_null("Player") as Node3D
		if pl != null:
			pos = pl.global_position
		if not _bound_prop_id.is_empty():
			var prop := PlacedPropRuntime.find_by_prop_id(main, _bound_prop_id) as Node3D
			if prop != null:
				pos = prop.global_position
	_probe = EspWorldProbe.for_main(main, pos)
	var gv := ServiceLocator.graph()
	if gv != null and is_instance_valid(gv):
		_probe.graph_model = gv.get("model")
	_probe.boot_h = _now_h() - 0.5
	_live.clear()
	_live_acc = 1.0


func _now_h() -> float:
	var main := get_tree().current_scene if get_tree() != null else null
	if main != null and main.has_method("get_absolute_hours"):
		return float(main.call("get_absolute_hours"))
	return float(Time.get_unix_time_from_system()) / 3600.0


func _process(delta: float) -> void:
	if not _active:
		return
	_live_acc += delta
	if _live_acc < 1.0:
		return
	_live_acc = 0.0
	_refresh_live()


func _refresh_live() -> void:
	if _probe == null or _design.is_empty():
		return
	var t := _now_h()
	var src := _probe.source()
	var node := str(_design["node"])
	var out := {}
	for e in _design["entities"]:
		var r := EspSim.reading(e, EspSim.unit_key(node, e), t, src)
		out[str(e["entity_id"])] = {"text": EspSim.format(e, r), "value": r["value"], "available": r["available"]}
	_live = out
	_diagram.call("set_readings", _readings())
	for eid in _ent_vals:
		var l: Label = _ent_vals[eid]
		if is_instance_valid(l) and _live.has(eid):
			l.text = str(_live[eid]["text"])


func _sync_board_pick() -> void:
	var id := str(_spec["board"])
	for i in _board_opt.item_count:
		if _board_opt.get_item_metadata(i) != null and str(_board_opt.get_item_metadata(i)) == id:
			if _board_opt.selected != i:
				_board_opt.select(i)
			break
	var b: Dictionary = _design["board"]
	var free := 0
	for p in EspBoards.pins(b):
		if EspBoards.pin_state(b, p) in ["free", "caveat", "input_only"]:
			free += 1
	var bits := PackedStringArray()
	bits.append("%s, ESPHome board %s" % [EspChips.get_chip(str(b["chip"]))["label"], b["board"]])
	bits.append(UiText.count(free, "usable GPIO", "usable GPIOs"))
	if b.has("screen"):
		bits.append("built-in %s screen (its pins are taken)" % str(b["screen"]))
	if b.has("pin_note"):
		bits.append(str(b["pin_note"]))
	_board_note.text = " · ".join(bits)


func _sync_diagram_selection() -> void:
	match str(_sel.get("kind", "")):
		"part":
			_diagram.call("set_selected", str(_sel["iid"]))
		"pin":
			_diagram.call("set_selected_pin", int(_sel["gpio"]))
		_:
			_diagram.call("set_selected", "")


func _clear(box: Node) -> void:
	for c in box.get_children():
		box.remove_child(c)
		c.queue_free()


func _refresh_palette() -> void:
	_clear(_palette)
	for cat in EspParts.CATEGORIES:
		var ids: Array = []
		for pid in EspParts.in_category(str(cat[0])):
			var p := EspParts.get_part(pid)
			var hay := ("%s %s %s %s" % [p["label"], p.get("desc", ""), EspParts.badge(p), cat[1]]).to_lower()
			if _part_filter == "" or Array(_part_filter.split(" ", false)).all(func(w): return hay.find(w) >= 0):
				ids.append(pid)
		if ids.is_empty():
			continue
		_palette.add_child(_caption(str(cat[1])))
		var flow := HFlowContainer.new()
		flow.add_theme_constant_override("h_separation", 3)
		flow.add_theme_constant_override("v_separation", 3)
		_palette.add_child(flow)
		for pid in ids:
			var p := EspParts.get_part(pid)
			var b := Button.new()
			b.name = "add_%s" % pid
			b.text = EspParts.short_label(p)
			b.tooltip_text = "%s — %s\n%s · %s\nClick to add it to the board." % [p["label"], EspParts.badge(p), p.get("desc", ""),
				{"3v3": "3.3 V", "5v": "needs 5 V", "any": "3.3-5 V"}.get(str(p.get("supply", "")), "")]
			b.focus_mode = Control.FOCUS_NONE
			b.add_theme_font_size_override("font_size", UITheme.FONT_SM)
			UITheme.style_button(b)
			b.pressed.connect(add_part.bind(pid))
			flow.add_child(b)


func _refresh_in_use() -> void:
	_clear(_in_use)
	if (_spec["parts"] as Array).is_empty():
		_in_use.add_child(_caption("Nothing yet: click a part above."))
		return
	for inst in _spec["parts"]:
		var iid := str(inst["iid"])
		var part := EspParts.get_part(str(inst["part"]))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 2)
		var b := Button.new()
		b.name = "use_%s" % iid
		b.text = "%s  · %s" % [inst["label"], EspParts.badge(part)]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		b.focus_mode = Control.FOCUS_NONE
		UITheme.style_button(b)
		if str(_sel.get("iid", "")) == iid:
			b.add_theme_color_override("font_color", UITheme.C_AMBER)
		b.pressed.connect(_select.bind({"kind": "part", "iid": iid}))
		row.add_child(b)
		var x := IconButton.make("trash-2", "Remove %s" % str(inst["label"]), remove_part.bind(iid))
		x.name = "remove_%s" % iid
		row.add_child(x)
		_in_use.add_child(row)


func _refresh_designs() -> void:
	_clear(_designs_box)
	for b in EspPresets.builtins():
		var btn := Button.new()
		btn.name = "builtin_%s" % str(b["id"])
		btn.text = str(b["label"])
		btn.tooltip_text = str(b["blurb"])
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.focus_mode = Control.FOCUS_NONE
		UITheme.style_button(btn)
		btn.pressed.connect(load_builtin.bind(str(b["id"])))
		_designs_box.add_child(btn)
	var blank := Button.new()
	blank.name = "new_blank"
	blank.text = "Empty board"
	blank.tooltip_text = "Start again with nothing wired"
	blank.alignment = HORIZONTAL_ALIGNMENT_LEFT
	blank.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(blank)
	blank.pressed.connect(func() -> void:
		var s := EspSpec.empty("New board")
		s["board"] = str(_spec.get("board", EspSpec.DEFAULT_BOARD))
		_sel = {}
		_set_spec(s))
	_designs_box.add_child(blank)
	if not _library.is_empty():
		_designs_box.add_child(_caption("Your designs"))
	for d in _library:
		var row := HBoxContainer.new()
		var btn2 := Button.new()
		btn2.text = str(d.get("label", "?"))
		btn2.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn2.focus_mode = Control.FOCUS_NONE
		UITheme.style_button(btn2)
		var sp: Dictionary = d.get("spec", {})
		btn2.pressed.connect(func() -> void:
			_sel = {}
			_set_spec(sp.duplicate(true))
			_fit_later())
		row.add_child(btn2)
		var lab := str(d.get("label", ""))
		row.add_child(IconButton.make("trash-2", "Forget this design", func() -> void:
			_library = EspPresets.forget_design(_library, lab)
			EspPresets.save_library(_library)
			_refresh_designs()))
		_designs_box.add_child(row)


# ---------------------------------------------------------------------------
# Right column
# ---------------------------------------------------------------------------

func _select(sel: Dictionary) -> void:
	_sel = sel
	_sync_diagram_selection()
	_refresh_in_use()
	_refresh_card()


func _inst(iid: String) -> Dictionary:
	for p in _spec["parts"]:
		if str(p["iid"]) == iid:
			return p
	return {}


func _refresh_card() -> void:
	_clear(_card)
	match str(_sel.get("kind", "")):
		"part":
			_part_card(str(_sel["iid"]))
		"pin":
			_pin_card(int(_sel["gpio"]))
		_:
			_board_card()


func _board_card() -> void:
	var b: Dictionary = _design["board"]
	_card.add_child(SectionHeader.make(str(b["label"]), "cpu", str(EspChips.get_chip(str(b["chip"]))["label"])))
	var n := 0
	for e in _design["entities"]:
		if str(e["iid"]) != "":
			n += 1
	_card.add_child(_caption("Node %s · %s · %s" % [_design["node"], UiText.count((_spec["parts"] as Array).size(), "part"),
		UiText.count(n, "entity", "entities")]))
	_card.add_child(_caption("Click a part or a pin in the diagram to see it here. Wi-Fi and the API key go in secrets.yaml (Export files writes a template)."))
	var diag := CheckBox.new()
	diag.name = "diagnostics"
	diag.text = "Also report uptime, Wi-Fi signal and online status"
	diag.button_pressed = bool(_spec.get("diagnostics", true))
	diag.toggled.connect(func(on: bool) -> void:
		var s := _spec.duplicate(true)
		s["diagnostics"] = on
		_set_spec(s))
	_card.add_child(diag)


func _part_card(iid: String) -> void:
	var inst := _inst(iid)
	if inst.is_empty():
		return
	var part := EspParts.get_part(str(inst["part"]))
	_card.add_child(SectionHeader.make(str(inst["label"]), "box", "%s · %s" % [part["label"], EspParts.badge(part)]))
	_card.add_child(_caption(str(part.get("desc", ""))))
	if part.has("note"):
		var nl := _caption(str(part["note"]))
		nl.add_theme_color_override("font_color", UITheme.C_WARN)
		_card.add_child(nl)
	var name_row := FormRow.text_edit("Name", "Name in Home Assistant", func(t: String) -> void:
		var s := _spec.duplicate(true)
		for p in s["parts"]:
			if str(p["iid"]) == iid:
				p["label"] = t.strip_edges()
		_set_spec(s), "Every entity this part makes starts with this name", "part_name")
	(name_row.control as LineEdit).text = str(inst["label"])
	_card.add_child(name_row)
	var addrs: Array = part.get("addr", [])
	if addrs.size() > 1:
		var items: Array = [[-1, "Auto"]]
		for a in addrs:
			items.append([int(a), "0x%02X" % int(a)])
		var ar := FormRow.option("I²C address", items, func(v: Variant) -> void:
			var s := _spec.duplicate(true)
			for p in s["parts"]:
				if str(p["iid"]) == iid:
					p["addr"] = int(v)
			_set_spec(s), str(part.get("addr_note", "")), "part_addr")
		FormRow.select_meta(ar.control as OptionButton, int(inst.get("addr", -1)))
		_card.add_child(ar)
	if float(part.get("update", 0)) > 0.0:
		var upd := float(inst.get("update_s", -1.0))
		if upd <= 0.0:
			upd = float(part["update"])
		var ur := FormRow.spin("Update every", maxf(1.0, float(part.get("min_update", 1))), 3600.0, 1.0, "s", func(v: float) -> void:
			var s := _spec.duplicate(true)
			for p in s["parts"]:
				if str(p["iid"]) == iid:
					p["update_s"] = v
			_set_spec(s), "How often the board reads it and sends it to Home Assistant", "part_update")
		ur.set_value(upd)
		_card.add_child(ur)
	# What each entity measures: the world here, or a graph item.
	var items := _graph_items()
	for e in part.get("ents", []):
		var dsrc := str(e.get("src", ""))
		var ch := EspBindings.choices(dsrc, items)
		if ch.is_empty():
			continue
		var act := dsrc.begins_with("actuator.")
		var opts: Array = [["", "Its own switch" if act else "The world here"]]
		opts.append_array(ch)
		var k := str(e["k"])
		var mr := FormRow.option("Follows" if act else "%s from" % str(e["name"]), opts, func(v: Variant) -> void:
			var s2 := _spec.duplicate(true)
			for p in s2["parts"]:
				if str(p["iid"]) == iid:
					var m: Dictionary = p.get("measures", {})
					if str(v) == "":
						m.erase(k)
					else:
						m[k] = str(v)
					p["measures"] = m
			_set_spec(s2), "What the twin's %s reads: the world at the board's spot, or a tank, battery or load on the graph" % str(e["name"]).to_lower(), "measures_%s" % k)
		FormRow.select_meta(mr.control as OptionButton, str((inst.get("measures", {}) as Dictionary).get(k, "")))
		_card.add_child(mr)
	# Where each pin goes.
	var assign: Dictionary = (_design["wire"]["assign"] as Dictionary).get(iid, {})
	var locks: Dictionary = _spec.get("locks", {})
	var any_lock := false
	for pin in part["pins"]:
		var label := str(pin[0])
		var v: Variant = assign.get(label, "")
		var to := "not connected"
		if v is int:
			to = "%s (GPIO%d)" % [EspBoards.label_of(_design["board"], int(v)), int(v)]
		elif str(v) != "":
			to = str(v)
		var lk := locks.has("%s:%s" % [iid, label])
		any_lock = any_lock or lk
		_card.add_child(FormRow.value(label, to + ("  · by hand" if lk else ""), "Pin %s (%s)" % [label, pin[1]]))
	if any_lock:
		var b := Button.new()
		b.name = "unlock_part"
		b.text = "Give its pins back to the tool"
		UITheme.style_button(b)
		b.pressed.connect(func() -> void:
			var s := _spec.duplicate(true)
			for k in (s["locks"] as Dictionary).keys():
				if str(k).begins_with(iid + ":"):
					(s["locks"] as Dictionary).erase(k)
			_set_spec(s))
		_card.add_child(b)
	if str(part.get("addr_note", "")) != "":
		_card.add_child(_caption("Address: " + str(part["addr_note"])))
	_card.add_child(_caption("Source: " + str(part.get("src_doc", ""))))
	var rm := Button.new()
	rm.name = "remove_part"
	rm.text = "Remove %s" % str(inst["label"])
	UITheme.style_button(rm)
	rm.add_theme_color_override("font_color", UITheme.C_ERROR)
	rm.pressed.connect(remove_part.bind(iid))
	_card.add_child(rm)


func _graph_items() -> Array:
	var gv := ServiceLocator.graph()
	if gv == null or not is_instance_valid(gv):
		return []
	var m: Variant = gv.get("model")
	if m == null or not ("items" in m):
		return []
	return m.get("items")


func _pin_card(g: int) -> void:
	var b: Dictionary = _design["board"]
	var label := EspBoards.label_of(b, g)
	var st := ""
	for p in EspBoards.pins(b):
		if int(p["gpio"]) == g:
			st = EspBoards.pin_state(b, p)
			break
	_card.add_child(SectionHeader.make("%s · GPIO%d" % [label, g], "plug", str(Diagram.STATE_WORDS.get(st, st))))
	for f in EspChips.functions_of(str(b["chip"]), g):
		_card.add_child(_caption("• " + f))
	var use := EspBoards.board_use(b, g)
	if use != "":
		_card.add_child(_caption("The board uses it for: " + use))
	var owners: Array = (_design["wire"]["used"] as Dictionary).get(g, [])
	if owners.is_empty():
		_card.add_child(_caption("Nothing is wired here. Drag a part's pin onto it to wire it yourself."))
	for o in owners:
		var who := str(o[0])
		var inst := _inst(who)
		_card.add_child(FormRow.value(str(o[1]), str(inst.get("label", who))))


func _refresh_checks() -> void:
	_clear(_checks_box)
	var e := EspDesign.count_level(_design, "error")
	var w := EspDesign.count_level(_design, "warn")
	if e > 0:
		_shell.set_badge(UiText.count(e, "problem") + " to fix", "error", "Scroll to the checks")
	elif w > 0:
		_shell.set_badge(UiText.count(w, "warning"), "warn", "Scroll to the checks")
	else:
		_shell.set_badge("Checks pass", "ok", "")
	if (_design["checks"] as Array).is_empty():
		_checks_box.add_child(_caption("Nothing to report."))
	for c in _design["checks"]:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var dot := Label.new()
		dot.text = {"error": "✕", "warn": "!", "info": "·"}.get(str(c["level"]), "·")
		dot.add_theme_color_override("font_color", {"error": UITheme.C_ERROR, "warn": UITheme.C_WARN}.get(str(c["level"]), UITheme.C_TEXT_M))
		row.add_child(dot)
		var col := VBoxContainer.new()
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var l := Label.new()
		l.text = str(c["text"])
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		col.add_child(l)
		var why := _caption(str(c["why"]))
		col.add_child(why)
		row.add_child(col)
		var ids: Array = c.get("ids", [])
		if not ids.is_empty():
			var show := Button.new()
			show.text = "Show"
			show.tooltip_text = "Select it"
			UITheme.style_button(show)
			show.pressed.connect(_select.bind({"kind": "part", "iid": str(ids[0])}))
			row.add_child(show)
		_checks_box.add_child(row)


func _refresh_power() -> void:
	var p: Dictionary = _design["power"]
	if _col != null:
		var over := float(p["ma_5v"]) > float(p["usb_ma"])
		_col.set_tiles([
			{"caption": "Parts", "value": str((_spec.get("parts", []) as Array).size()), "tip": "Parts wired to the board"},
			{"caption": "3.3 V rail", "value": "%d mA" % int(p["ma_3v3"]), "tip": "Of the regulator's %d mA" % int(p["reg_ma"]),
				"level": "warn" if float(p["ma_3v3"]) > float(p["reg_ma"]) else ""},
			{"caption": "5 V in", "value": "%d mA" % int(p["ma_5v"]), "level": "warn" if over else "",
				"tip": "More than a USB port gives" if over else "Fine on USB"}])
	_power_lbl.text = "3.3 V rail: %d of %d mA (board + 3.3 V parts)\n5 V in: %d mA total%s" % [
		int(p["ma_3v3"]), int(p["reg_ma"]), int(p["ma_5v"]),
		" — more than a USB port gives" if float(p["ma_5v"]) > float(p["usb_ma"]) else ", fine on USB"]


func _refresh_entities() -> void:
	_clear(_ents_box)
	_ent_vals.clear()
	_ents_box.add_child(_caption("The twin reads the world at the site, now: the weather, sunlight and air quality where you stand, with each part's own accuracy and noise."))
	for e in _design["entities"]:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var l := Label.new()
		l.text = str(e["entity_id"])
		l.tooltip_text = "%s%s" % [e["name"], (" (" + str(e["unit"]) + ")") if str(e["unit"]) != "" else ""]
		l.mouse_filter = Control.MOUSE_FILTER_PASS
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		l.add_theme_color_override("font_color", UITheme.C_TEXT_S if str(e["iid"]) != "" else UITheme.C_TEXT_M)
		row.add_child(l)
		var u := Label.new()
		u.name = "val_%s" % EspEntityNames.ha_slug(str(e["entity_id"]))
		var lv: Dictionary = _live.get(str(e["entity_id"]), {})
		u.text = str(lv.get("text", str(e["unit"])))
		u.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		u.add_theme_color_override("font_color", UITheme.C_PRIMARY)
		var note := _probe.note_of(str(e["src"])) if _probe != null else ""
		if note != "":
			u.tooltip_text = "Twin: " + note
			u.mouse_filter = Control.MOUSE_FILTER_PASS
		row.add_child(u)
		_ents_box.add_child(row)
		_ent_vals[str(e["entity_id"])] = u


func _refresh_bom() -> void:
	_clear(_bom_box)
	for r in _design["bom"]:
		var l := Label.new()
		l.text = "%d × %s — $%.2f" % [int(r["qty"]), r["item"], float(r["price"]) * int(r["qty"])]
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		_bom_box.add_child(l)
	_bom_box.add_child(_caption("About $%.0f in parts (single units online)." % float(_design["cost_usd"])))


# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

func _set_tab(t: String) -> void:
	_tab = t
	for k in _tab_btns:
		(_tab_btns[k] as Button).button_pressed = k == t
	_diagram.visible = t == "diagram"
	_yaml_view.visible = t == "yaml"
	_cmp.visible = t == "compare"
	if t == "compare":
		_refresh_compare_rows()


func _fit_later() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if is_instance_valid(_diagram):
		_diagram.call("fit")


func _on_name_submitted(t: String) -> void:
	if t.strip_edges() == "" or t.strip_edges() == str(_spec["name"]):
		return
	var s := _spec.duplicate(true)
	s["name"] = t.strip_edges()
	_set_spec(s)


func _on_part_moved(iid: String, pos: Vector2) -> void:
	# Layout only: not an undo step, never re-solves (key_of leaves it out).
	var lay: Dictionary = _spec.get("layout", {})
	lay[iid] = [pos.x, pos.y]
	_spec["layout"] = lay
	_select({"kind": "part", "iid": iid})


func _on_wire_drawn(iid: String, pin_label: String, gpio: int) -> void:
	var inst := _inst(iid)
	var part := EspParts.get_part(str(inst.get("part", "")))
	var role := ""
	for p in part.get("pins", []):
		if str(p[0]) == pin_label:
			role = str(p[1])
	if role in ["vcc", "gnd", "nc", ""]:
		_set_status("%s %s is power: the tool wires it to the right rail." % [inst.get("label", iid), pin_label])
		return
	var s := _spec.duplicate(true)
	(s["locks"] as Dictionary)["%s:%s" % [iid, pin_label]] = gpio
	_set_spec(s)
	_select({"kind": "part", "iid": iid})
	var a: Variant = ((_design["wire"]["assign"] as Dictionary).get(iid, {}) as Dictionary).get(pin_label, null)
	if a is int and int(a) == gpio:
		_set_status("Wired %s %s to %s by hand." % [inst["label"], pin_label, EspBoards.label_of(_design["board"], gpio)])
	else:
		_set_status("That pin can't take it: see the checks.")


func _on_wire_removed(iid: String, pin_label: String) -> void:
	var key := "%s:%s" % [iid, pin_label]
	if not (_spec.get("locks", {}) as Dictionary).has(key):
		_set_status("The tool placed that wire. Drag the part's pin onto another board pin to choose your own.")
		return
	var s := _spec.duplicate(true)
	(s["locks"] as Dictionary).erase(key)
	_set_spec(s)
	_set_status("Gave %s back to the tool." % pin_label)


func _on_rewire_all() -> void:
	if (_spec.get("locks", {}) as Dictionary).is_empty():
		_set_status("Every wire is already the tool's.")
		return
	var s := _spec.duplicate(true)
	s["locks"] = {}
	_set_spec(s)
	_set_status("The tool wired the whole board.")


func _on_place() -> void:
	var main := _main()
	if main == null:
		_set_status("Placing needs a world.")
		return
	var r: Dictionary = PlacedPropService.begin_placement(main, EspBuilder.MODEL_ID, {
		"record_extra": {"esp_spec": _spec.duplicate(true), "collision_enabled": true}})
	if not bool(r.get("ok", true)):
		_set_status(str(r.get("error", "Could not start placing.")))
		return
	close()


func _on_apply() -> void:
	var main := _main()
	if main == null or _bound_prop_id.is_empty():
		return
	PlacedPropService.update_prop_record(main, _bound_prop_id, {"esp_spec": _spec.duplicate(true)}, true)
	PlacedPropService.seed_esplab(main, _bound_prop_id)
	_set_status("Applied to the placed board: its twin and graph node follow.")


func _on_copy_yaml() -> void:
	DisplayServer.clipboard_set(str(_design["yaml"]))
	_set_status("YAML copied. Paste it into a new device in the ESPHome dashboard, and fill in secrets.yaml.")


func _on_save_design() -> void:
	var lab := str(_spec["name"])
	var s := _spec.duplicate(true)
	_library = EspPresets.save_design(_library, lab, s)
	if EspPresets.save_library(_library):
		_set_status("Saved “%s” to your designs." % lab)
	else:
		_set_status("Couldn't write the library.")
	_refresh_designs()


func _on_export() -> void:
	var dir := EXPORT_DIR.path_join(str(_design["node"]))
	DirAccess.make_dir_recursive_absolute(dir)
	var yaml_path := dir.path_join(str(_design["node"]) + ".yaml")
	var f := FileAccess.open(yaml_path, FileAccess.WRITE)
	if f == null:
		_set_status("Couldn't write %s." % yaml_path)
		return
	f.store_string(str(_design["yaml"]))
	f.close()
	# Never overwrite secrets the player has filled in.
	var sec := dir.path_join("secrets.yaml")
	if not FileAccess.file_exists(sec):
		f = FileAccess.open(sec, FileAccess.WRITE)
		f.store_string(str(_design["secrets"]))
		f.close()
	f = FileAccess.open(dir.path_join("design.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(_spec, "\t"))
	f.close()
	await _save_diagram_png(dir.path_join("wiring.png"))
	_set_status("Wrote %s, secrets.yaml, wiring.png and design.json to %s" % [yaml_path.get_file(), ProjectSettings.globalize_path(dir)])


func export_dir() -> String:
	return EXPORT_DIR.path_join(str(_design.get("node", "")))


func _save_diagram_png(path: String) -> void:
	var was := _tab
	_set_tab("diagram")
	await RenderingServer.frame_post_draw
	var vp := get_viewport()
	var img := vp.get_texture().get_image()
	var xf := vp.get_final_transform()
	var r := _diagram.get_global_rect()
	var pos := xf * r.position
	var sz := r.size * xf.get_scale()
	var rect := Rect2i(Vector2i(pos), Vector2i(sz)).intersection(Rect2i(Vector2i.ZERO, img.get_size()))
	if rect.size.x > 0 and rect.size.y > 0:
		img.get_region(rect).save_png(path)
	_set_tab(was)


func _set_status(t: String) -> void:
	if _status != null:
		_status.text = t


func _input(e: InputEvent) -> void:
	if not _active or not (e is InputEventKey) or not e.pressed or e.echo:
		return
	var fo := get_viewport().gui_get_focus_owner()
	if fo is LineEdit or fo is TextEdit or fo is SpinBox:
		return
	var k := e as InputEventKey
	if k.keycode == KEY_Z and k.ctrl_pressed:
		if k.shift_pressed:
			_redo_step()
		else:
			_undo_step()
		get_viewport().set_input_as_handled()
	elif k.keycode == KEY_Y and k.ctrl_pressed:
		_redo_step()
		get_viewport().set_input_as_handled()
	elif (k.keycode == KEY_DELETE or k.keycode == KEY_BACKSPACE) and str(_sel.get("kind", "")) == "part":
		remove_part(str(_sel["iid"]))
		get_viewport().set_input_as_handled()
	elif k.keycode == KEY_F and not k.ctrl_pressed:
		_diagram.call("fit")
		get_viewport().set_input_as_handled()


# ---------------------------------------------------------------------------
# Compare with the real board (Phase 6)
# ---------------------------------------------------------------------------

const SPANS := [[6.0, "Last 6 hours"], [24.0, "Last 24 hours"], [72.0, "Last 3 days"], [168.0, "Last 7 days"]]


func _build_compare() -> void:
	_cmp = VBoxContainer.new()
	_cmp.name = "Compare"
	_cmp.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_cmp.add_theme_constant_override("separation", 6)
	_cmp.visible = false
	_shell.centre.add_child(_cmp)
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 6)
	_cmp.add_child(bar)
	_cmp_span = OptionButton.new()
	_cmp_span.name = "compare_span"
	for i in SPANS.size():
		_cmp_span.add_item(str(SPANS[i][1]))
		_cmp_span.set_item_metadata(i, float(SPANS[i][0]))
	_cmp_span.select(1)
	bar.add_child(_cmp_span)
	var find := Button.new()
	find.name = "compare_find"
	find.text = "Find my board"
	find.tooltip_text = "Look in Home Assistant for the entities this YAML makes (by name and unit)"
	UITheme.style_button(find)
	find.pressed.connect(find_real_board)
	bar.add_child(find)
	var go := Button.new()
	go.name = "compare_run"
	go.text = "Compare"
	go.tooltip_text = "Fetch the real board's history from Home Assistant and lay the twin over it"
	UITheme.style_button(go)
	go.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	go.pressed.connect(func() -> void: run_compare())
	bar.add_child(go)
	_cmp_status = Label.new()
	_cmp_status.name = "compare_status"
	_cmp_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cmp_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_cmp_status.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_cmp_status.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	bar.add_child(_cmp_status)
	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_cmp.add_child(sc)
	_cmp_rows = VBoxContainer.new()
	_cmp_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cmp_rows.add_theme_constant_override("separation", 10)
	sc.add_child(_cmp_rows)


func _ha() -> Node:
	return get_tree().root.get_node_or_null("HomeAssistant") if get_tree() != null else null


func compare_results() -> Dictionary:
	return _cmp_results


func set_compare_span(hours: float) -> void:
	for i in _cmp_span.item_count:
		if absf(float(_cmp_span.get_item_metadata(i)) - hours) < 0.01:
			_cmp_span.select(i)


## Match the design's entities to Home Assistant's; kept in spec.real.
func find_real_board() -> int:
	var svc := _ha()
	if svc == null or not bool(svc.call("is_authed")):
		_cmp_status.text = "Connect Home Assistant first (Settings → Home Assistant)."
		_refresh_compare_rows()
		return 0
	var m := EspCompare.match_entities(_design, svc.call("catalog"), _spec.get("real", {}))
	var s := _spec.duplicate(true)
	s["real"] = m
	_set_spec(s, false)
	var want := 0
	for e in _design["entities"]:
		if str(e["iid"]) != "":
			want += 1
	_cmp_status.text = "Found %d of %d entities in Home Assistant%s." % [m.size(), want,
		"" if m.size() == want else " (pick the others by hand, or flash the YAML first)"]
	_refresh_compare_rows()
	return m.size()


## Fetch the real history and the twin over the span; fills _cmp_results.
func run_compare() -> void:
	if _cmp_running:
		return
	var svc := _ha()
	if svc == null or not bool(svc.call("is_authed")):
		_cmp_status.text = "Connect Home Assistant first (Settings → Home Assistant)."
		return
	if (_spec.get("real", {}) as Dictionary).is_empty():
		find_real_board()
	var real_map: Dictionary = _spec.get("real", {})
	if real_map.is_empty():
		_cmp_status.text = "None of this board's entities are in Home Assistant yet."
		return
	_cmp_running = true
	var main := _main()
	var clock: Object = main.get("clock") if main != null else null
	if clock == null:
		clock = CelestialClock.new()
	var span_h := float(_cmp_span.get_item_metadata(_cmp_span.selected))
	var t1u := float(Time.get_unix_time_from_system())
	var t0u := t1u - span_h * 3600.0
	var t0 := SiteTime.unix_to_site_abs(clock, t0u)
	var t1 := SiteTime.unix_to_site_abs(clock, t1u)
	var probe := _compare_probe()
	var src := probe.source()
	var node := str(_design["node"])
	_cmp_results = {}
	var done := 0
	for e in _design["entities"]:
		var eid := str(e["entity_id"])
		if str(e["iid"]) == "" or not real_map.has(eid):
			continue
		_cmp_status.text = "Fetching %s…" % str(real_map[eid])
		var box := {"rows": null}
		svc.call("request_history", str(real_map[eid]), t0u, t1u, func(rows: Array) -> void: box["rows"] = rows)
		var waited := 0
		while box["rows"] == null and waited < 600:
			await get_tree().process_frame
			waited += 1
		var real := EspCompare.parse_history(box["rows"] if box["rows"] != null else [], clock)
		var twin := EspCompare.numeric(EspSim.series(e, EspSim.unit_key(node, e), t0, t1, src, 4000, true))
		var step := maxf(span_h / 600.0, float(e.get("update_s", 60.0)) / 3600.0)
		var st := EspCompare.stats(real, twin, t0, t1, step)
		_cmp_results[eid] = {"real": real, "twin": twin, "stats": st, "verdict": EspCompare.verdict(st, e),
			"t0": t0, "t1": t1, "real_id": str(real_map[eid])}
		done += 1
	_cmp_running = false
	_cmp_status.text = "Compared %s over the %s (the twin's ideal reading: the weather data at the board's spot, through this design's filters)." % [
		UiText.count(done, "entity", "entities"), str(_cmp_span.get_item_text(_cmp_span.selected)).to_lower()]
	_refresh_compare_rows()


## A probe for the comparison: the bound board's spot (else the player's),
## the graph, and tank history from the tanks' timelines.
func _compare_probe() -> EspWorldProbe:
	var main := _main()
	var pos := Vector3.ZERO
	if main != null:
		var pl := main.get_node_or_null("Player") as Node3D
		if pl != null:
			pos = pl.global_position
		if not _bound_prop_id.is_empty():
			var prop := PlacedPropRuntime.find_by_prop_id(main, _bound_prop_id) as Node3D
			if prop != null:
				pos = prop.global_position
	var p := EspWorldProbe.for_main(main, pos)
	var gv := ServiceLocator.graph()
	if gv != null and is_instance_valid(gv):
		p.graph_model = gv.get("model")
		var rf: Object = gv.get("_resource_flow")
		if rf != null:
			p.tank_level_fn = func(gid: String, t: float) -> float:
				var tl: Object = rf.call("get_timeline", gid)
				return float(tl.call("level_at", t)) if tl != null else NAN
	return p


func _refresh_compare_rows() -> void:
	if _cmp_rows == null:
		return
	_clear(_cmp_rows)
	var svc := _ha()
	if svc == null or not bool(svc.call("is_authed")):
		_cmp_rows.add_child(_caption("The comparison reads your real board's history from Home Assistant. Connect it in Settings → Home Assistant, flash this YAML to the board, then come back."))
		return
	var cat: Array = svc.call("catalog")
	var real_map: Dictionary = _spec.get("real", {})
	for e in _design["entities"]:
		if str(e["iid"]) == "":
			continue
		var eid := str(e["entity_id"])
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 3)
		var head := HBoxContainer.new()
		head.add_theme_constant_override("separation", 8)
		var t := Label.new()
		t.text = str(e["name"])
		t.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		head.add_child(t)
		var pick := OptionButton.new()
		pick.name = "real_%s" % EspEntityNames.ha_slug(eid)
		pick.fit_to_longest_item = false
		pick.custom_minimum_size = Vector2(300, 0)
		pick.clip_text = true
		pick.add_item("Not on the real board")
		pick.set_item_metadata(0, "")
		for row in cat:
			var rid := str(row.get("entity_id", ""))
			if not rid.begins_with(str(e["kind"]) + "."):
				continue
			if str(e["kind"]) == "sensor" and str(row.get("unit", "")) != "" and str(e["unit"]) != "" and not EspCompare.units_agree(str(row.get("unit", "")), str(e["unit"])):
				continue
			pick.add_item(rid)
			pick.set_item_metadata(pick.item_count - 1, rid)
		FormRow.select_meta(pick, str(real_map.get(eid, "")))
		pick.tooltip_text = str(real_map.get(eid, "Which Home Assistant entity is the real board's"))
		pick.item_selected.connect(func(i: int) -> void:
			var s := _spec.duplicate(true)
			var rm: Dictionary = s.get("real", {})
			var v := str(pick.get_item_metadata(i))
			if v == "":
				rm.erase(eid)
			else:
				rm[eid] = v
			s["real"] = rm
			_set_spec(s, false))
		head.add_child(pick)
		box.add_child(head)
		var res: Dictionary = _cmp_results.get(eid, {})
		if not res.is_empty():
			var ch: Control = CompareChart.new()
			ch.name = "chart_%s" % EspEntityNames.ha_slug(eid)
			box.add_child(ch)
			ch.call("set_data", res["real"], res["twin"], float(res["t0"]), float(res["t1"]), str(e["unit"]))
			var st: Dictionary = res["stats"]
			var line := Label.new()
			line.name = "stats_%s" % EspEntityNames.ha_slug(eid)
			line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			line.add_theme_font_size_override("font_size", UITheme.FONT_SM)
			if int(st["n"]) < EspCompare.MIN_POINTS:
				line.text = "Not enough readings from the real board over this span."
				line.add_theme_color_override("font_color", UITheme.C_TEXT_M)
			else:
				var u := str(e["unit"])
				var verdict := str(res["verdict"])
				line.text = "Real − twin: %+.2f %s · typical gap %.2f %s · r %s · %s — %s" % [float(st["bias"]), u, float(st["rmse"]), u,
					("%.2f" % float(st["r"])) if not is_nan(float(st["r"])) else "–", UiText.pct(float(st["coverage"])) + " covered",
					{"good": "within the part's accuracy", "fair": "a little outside its accuracy", "poor": "well outside its accuracy: calibrate it, or check where it is mounted"}.get(verdict, verdict)]
				line.add_theme_color_override("font_color", {"good": UITheme.C_OK, "fair": UITheme.C_WARN, "poor": UITheme.C_ERROR}.get(verdict, UITheme.C_TEXT_S))
			box.add_child(line)
			if str(e["kind"]) == "sensor" and int(st["n"]) >= EspCompare.MIN_POINTS:
				var row := HBoxContainer.new()
				row.add_theme_constant_override("separation", 6)
				for mode in [["offset", "Calibrate: offset", "Add an offset filter to this entity so the real board reads like the twin"],
						["linear", "Calibrate: scale + offset", "Add a calibrate_linear filter fitted over the range seen"]]:
					var f := EspCompare.calibration(st, str(mode[0]))
					var b := Button.new()
					b.name = "cal_%s_%s" % [str(mode[0]), EspEntityNames.ha_slug(eid)]
					b.text = str(mode[1])
					b.tooltip_text = str(mode[2])
					b.disabled = f.is_empty()
					UITheme.style_button(b)
					var iid := str(e["iid"])
					var k := str(e["k"])
					b.pressed.connect(func() -> void: apply_calibration(iid, k, f))
					row.add_child(b)
				box.add_child(row)
		_cmp_rows.add_child(box)


## Write a calibration filter into the design (YAML); the twin ignores it.
func apply_calibration(iid: String, k: String, f: Dictionary) -> void:
	_set_spec(EspCompare.with_calibration(_spec, iid, k, f))
	var what := ("offset %+.2f" % float(f["offset"])) if f.has("offset") else "a scale and offset"
	_cmp_status.text = "Calibration written into the YAML (%s). Flash the board, then compare again." % what
	_refresh_compare_rows()
