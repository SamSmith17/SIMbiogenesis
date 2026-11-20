extends VBoxContainer

## The Battery Lab's "Bank" bench, under the 3D view: how many packs in
## series and in parallel, how they are mounted, the bus, the wiring, the
## fuses and the run to the inverter; then the bank's numbers worked out, a
## table of every cable (from → to, length, gauge, current, drop, share), the
## bill of materials and the checks. The modal owns it (`modal`), solves the
## bank (BankDesign) and draws it (BankBuilder).

signal bank_changed(path: String, value: Variant)
signal row_selected(id: String)
signal view_changed(v: String)

const BENCH := preload("res://scenes/ui/batterylab_bank_bench.gd")
const VIEWS := ["cables", "bom", "checks", "bench"]

var modal: Control = null
var design: Dictionary = {}
var _rows: Dictionary = {}
var _summary: Label
var _tabs: TabBar
var _tree: Tree
var _place_btn: Button
var _apply_btn: Button
var _export_btn: Button
var _view := "cables"
var _bench: Control = null

const FIELDS := [
	["series", "In series", "spin", 1.0, 16.0, 1.0, "", "Packs joined end to end: their voltages add (only packs made for it)"],
	["parallel", "In parallel", "spin", 1.0, 32.0, 1.0, "", "Strings side by side on the bus: their amp-hours add"],
	["mount", "Mounted", "option", "mounts", "", 0.0, "", "Where the packs stand"],
	["bus", "Bus", "option", "buses", "", 0.0, "", "What the strings land on: a busbar pair or a distributor box"],
	["bus_bar", "Bus bar", "option", "bars", "", 0.0, "", "The copper bars' size: sized for the current, or your own"],
	["bus_stack", "Bars a pole", "option", "stacks", "", 0.0, "", "Bars laid together on each pole: more carry more current"],
	["wiring", "Wiring", "option", "wirings", "", 0.0, "", "How the strings reach the bus: equal lengths share the current evenly"],
	["fuse", "Fuses", "option", "fuses", "", 0.0, "", "One per string, at its positive"],
	["main_run_m", "To the inverter", "spin", 0.3, 30.0, 0.1, "m", "The run of main cable from the bus to the inverter"],
	["disconnect", "Disconnect", "check", "", "", 0.0, "", "A battery switch on the main positive"],
	["comms", "Comms chain", "check", "", "", 0.0, "", "Packs daisy-chained so the inverter hears every BMS"],
]


func _ready() -> void:
	add_theme_constant_override("separation", 6)
	var grid := HFlowContainer.new()
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 4)
	add_child(grid)
	for f in FIELDS:
		var path := str(f[0])
		var box := HBoxContainer.new()
		box.add_theme_constant_override("separation", 4)
		var l := Label.new()
		l.text = str(f[1])
		l.tooltip_text = str(f[7])
		l.mouse_filter = Control.MOUSE_FILTER_PASS
		l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		l.add_theme_color_override("font_color", UITheme.C_TEXT_S)
		box.add_child(l)
		var c: Control
		match str(f[2]):
			"spin":
				var sb := SpinBox.new()
				sb.min_value = float(f[3])
				sb.max_value = float(f[4])
				sb.step = float(f[5])
				sb.suffix = str(f[6])
				sb.select_all_on_focus = true
				sb.custom_minimum_size = Vector2(84, 0)
				sb.value_changed.connect(func(v: float) -> void: bank_changed.emit(path, v))
				c = sb
			"option":
				var ob := OptionButton.new()
				ob.fit_to_longest_item = false
				ob.custom_minimum_size = Vector2(150, 0)
				var tbl: Dictionary = _table(str(f[3]))
				for k in tbl:
					ob.add_item(str(tbl[k]))
					ob.set_item_metadata(ob.item_count - 1, str(k))
				ob.item_selected.connect(func(i: int) -> void: bank_changed.emit(path, str(ob.get_item_metadata(i))))
				c = ob
			_:
				var cb := CheckBox.new()
				cb.text = "On"
				cb.toggled.connect(func(on: bool) -> void: bank_changed.emit(path, on))
				c = cb
		c.name = "bank_" + path
		c.tooltip_text = str(f[7])
		box.add_child(c)
		grid.add_child(box)
		_rows[path] = c
	_summary = Label.new()
	_summary.name = "bank_summary"
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_summary.add_theme_font_override("font", UITheme.font("regular", true))
	_summary.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	add_child(_summary)
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 6)
	add_child(bar)
	_tabs = TabBar.new()
	_tabs.name = "bank_tabs"
	_tabs.add_tab("Cables")
	_tabs.add_tab("Bill of materials")
	_tabs.add_tab("Checks")
	_tabs.add_tab("Bench")
	_tabs.set_tab_tooltip(3, "The whole bank on a test bench: every pack's BMS and every string's fuse, the strings sharing the load")
	_tabs.tab_changed.connect(func(i: int) -> void:
		_view = VIEWS[i]
		_tree.visible = _view != "bench"
		_bench.visible = _view == "bench"
		if _view == "bench" and (_bench.get("result") as Dictionary).is_empty() and not design.is_empty():
			_bench.call("run_scenario", str(_bench.call("scenario_id")))
		view_changed.emit(_view)
		_fill())
	_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(_tabs)
	_export_btn = Button.new()
	_export_btn.name = "bank_export"
	_export_btn.text = "Export files"
	_export_btn.tooltip_text = "The bill of materials (CSV), a single-line drawing (SVG) and the design (JSON), in your user folder"
	UITheme.style_button(_export_btn)
	_export_btn.pressed.connect(func() -> void: modal.call("export_bank"))
	bar.add_child(_export_btn)
	_apply_btn = Button.new()
	_apply_btn.name = "bank_apply"
	_apply_btn.text = "Apply to placed bank"
	UITheme.style_button(_apply_btn)
	_apply_btn.visible = false
	_apply_btn.pressed.connect(func() -> void: modal.call("apply_bank"))
	bar.add_child(_apply_btn)
	_place_btn = Button.new()
	_place_btn.name = "bank_place"
	_place_btn.text = "Place bank in world"
	_place_btn.tooltip_text = "Set this bank down in the world: it joins the graph as one battery with its BMS limits"
	UITheme.style_button(_place_btn)
	_place_btn.pressed.connect(func() -> void: modal.call("place_bank"))
	bar.add_child(_place_btn)
	_tree = Tree.new()
	_tree.name = "bank_tree"
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.custom_minimum_size = Vector2(0, 110)
	_tree.hide_root = true
	_tree.select_mode = Tree.SELECT_ROW
	_tree.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_tree.item_selected.connect(func() -> void:
		var it := _tree.get_selected()
		if it != null and it.get_metadata(0) != null:
			row_selected.emit(str(it.get_metadata(0))))
	add_child(_tree)
	_bench = BENCH.new()
	_bench.name = "bank_bench"
	_bench.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_bench.visible = false
	add_child(_bench)


static func _table(name: String) -> Dictionary:
	match name:
		"mounts":
			return BankSpec.MOUNT_WORDS
		"buses":
			return BankSpec.BUS_WORDS
		"wirings":
			return BankSpec.WIRING_WORDS
		"fuses":
			return BankSpec.FUSE_WORDS
		"bars":
			return BankSpec.bar_words()
		"stacks":
			return BankSpec.stack_words()
	return {}


func set_bound(bound: bool) -> void:
	_apply_btn.visible = bound
	_place_btn.text = "Place a copy" if bound else "Place bank in world"


func set_design(d: Dictionary) -> void:
	design = d
	var b: Dictionary = d["spec"]
	for path in _rows:
		var c: Control = _rows[path]
		var v: Variant = b.get(path)
		if c is SpinBox:
			(c as SpinBox).set_value_no_signal(float(v))
		elif c is OptionButton:
			FormRow.select_meta(c as OptionButton, str(v))
		elif c is CheckBox:
			(c as CheckBox).set_pressed_no_signal(bool(v))
	for bk in ["bus_bar", "bus_stack"]:
		var bo := _rows.get(bk) as OptionButton
		if bo != null:
			bo.disabled = str(d["bus"]) == "distributor"
			if bo.disabled:
				bo.tooltip_text = "A distributor box has its own bars (rated %.0f A)" % BankDesign.DIST_RATING_A
			elif bk == "bus_bar":
				bo.tooltip_text = "The copper bars' size: sized for the current, or your own"
			else:
				bo.tooltip_text = "Bars laid together on each pole: more carry more current"
	var run_sb := _rows.get("main_run_m") as SpinBox
	if run_sb != null:
		var routed := float(b.get("main_routed_m", -1.0)) > 0.0
		run_sb.editable = not routed
		run_sb.tooltip_text = ("Routed in 3D to the placed inverter: %.1f m. Move the bank or the inverter to change it." % float(b["main_routed_m"])) if routed \
			else "The run of main cable from the bus to the inverter"
		if routed:
			run_sb.set_value_no_signal(float(b["main_routed_m"]))
	var e: Dictionary = d["electrical"]
	var pd: Dictionary = d["pack"]
	var pe: Dictionary = pd["electrical"]
	var N := int(d["series"])
	var M := int(d["parallel"])
	var fuse: Dictionary = d["fuse"]
	_summary.text = "%d × %.1f V in series = %.1f V · %d strings × %.0f Ah = %.0f Ah · %.1f kWh (%.1f usable) · %.0f A continuous (%s strings share %.0f–%.0f %%) · fault current %s A · %s · %.0f kg · $%s (estimate)" % [
		N, float(pe["v_nom"]), float(e["v_nom"]), M, float(pe["ah"]), float(e["ah"]), float(e["wh"]) * 0.001,
		float(e["usable_wh"]) * 0.001, float(e["cont_discharge_a"]), "the" if M > 1 else "one", float(e["min_share"]) * 100.0,
		float(e["max_share"]) * 100.0, UiText.thousands(int(e["i_sc"])),
		("%s %.0f A fuse per string" % [fuse["label"], float(fuse["amps"])]) if not fuse.is_empty() else "no fuses",
		float(d["mass_kg"]), UiText.thousands(int(d["cost_usd"]))]
	var errs := 0
	for c2 in (d["checks"] as Array):
		if str(c2["level"]) == "error":
			errs += 1
	_tabs.set_tab_title(2, "Checks (%d)" % (d["checks"] as Array).size() if errs == 0 else "Checks (%d to fix)" % errs)
	_bench.call("set_design", d)
	_fill()


func bench() -> Control:
	return _bench


func view() -> String:
	return _view


func set_view(v: String) -> void:
	_tabs.current_tab = VIEWS.find(v)


func tree() -> Tree:
	return _tree


func _fill() -> void:
	_tree.clear()
	if design.is_empty():
		return
	var root := _tree.create_item()
	match _view:
		"cables":
			_tree.columns = 7
			_titles(["Cable", "Length", "Gauge", "Amps", "Drop", "Share", ""])
			var share := {}
			for st in (design["strings"] as Array):
				share[int(st["j"])] = float(st["share"])
			for cb in (design["cables"] as Array):
				var it := _tree.create_item(root)
				it.set_text(0, str(cb["label"]))
				it.set_metadata(0, str(cb["id"]))
				it.set_text(1, "%.2f m" % (float(cb["len_mm"]) * 0.001))
				it.set_text(2, str(cb["gauge"]))
				it.set_text(3, "%.0f A" % float(cb["amps"]))
				it.set_text(4, "%.2f %%" % float(cb["drop_pct"]))
				var sid := str(cb["id"])
				if sid.begins_with("str_"):
					it.set_text(5, "%.1f %%" % (float(share.get(int(sid.get_slice("_", 2)), 0.0)) * 100.0))
				var notes: Array = []
				if bool(cb.get("upsized", false)):
					notes.append("up a size for the drop")
				if bool(cb.get("coiled", false)):
					notes.append("cut to the longest, spare coiled")
				it.set_text(6, ", ".join(PackedStringArray(notes)))
				it.set_custom_color(0, BattBuilder.C_RED.lightened(0.3) if str(cb["color"]) == "red" else UITheme.C_TEXT)
		"bom":
			_tree.columns = 5
			_titles(["Item", "Qty", "Each", "Total", "Note"])
			var bom: Dictionary = design["bom"]
			for r in (bom["rows"] as Array):
				var it := _tree.create_item(root)
				it.set_text(0, "%s: %s" % [r["group"], r["item"]])
				it.set_text(1, "%s %s" % [_qty(float(r["qty"])), r["unit"]])
				it.set_text(2, "$%.2f" % float(r["each_usd"]))
				it.set_text(3, "$%.0f" % float(r["total_usd"]))
				it.set_text(4, str(r["note"]))
				it.set_tooltip_text(4, str(r["note"]))
			var tot := _tree.create_item(root)
			tot.set_text(0, "Total (estimate)")
			tot.set_text(3, "$%s" % UiText.thousands(int(bom["total_usd"])))
			tot.set_text(4, "%.0f kg" % float(bom["mass_kg"]))
		"checks":
			_tree.columns = 2
			_titles(["", "Check"])
			for c in (design["checks"] as Array):
				var it := _tree.create_item(root)
				it.set_text(0, {"error": "✗", "warn": "!", "info": "i"}.get(str(c["level"]), "·"))
				it.set_custom_color(0, {"error": UITheme.C_ERROR, "warn": UITheme.C_AMBER}.get(str(c["level"]), UITheme.C_INFO))
				it.set_text(1, str(c["text"]))
				it.set_tooltip_text(1, str(c["why"]))
				var ids: Array = c.get("ids", [])
				if not ids.is_empty():
					it.set_metadata(0, str(ids[0]))
			if (design["checks"] as Array).is_empty():
				_tree.create_item(root).set_text(1, "No problems found.")


func _titles(t: Array) -> void:
	_tree.column_titles_visible = true
	for i in t.size():
		_tree.set_column_title(i, str(t[i]))
		_tree.set_column_expand(i, i == 0 or (i == t.size() - 1 and t.size() > 3))
		if i > 0 and i < t.size() - 1:
			_tree.set_column_custom_minimum_width(i, 72)


static func _qty(q: float) -> String:
	return str(int(q)) if is_equal_approx(q, roundf(q)) else "%.1f" % q
