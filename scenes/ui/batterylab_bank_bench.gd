extends VBoxContainer

## The Battery Lab's bank bench (the Bank tab's "Bench" view): the whole bank
## run through a scenario by BankSim — every pack's BMS, every string's fuse,
## the strings sharing the bus. A chart of each string's current and the bus
## voltage, one bar per string (its charge, coloured by its state), the event
## log (click to jump) and the summary. The modal paints the studio's packs
## from the frame shown (`frame_changed`).

signal frame_changed(f: Dictionary)

const PLAY_SECONDS := 20.0
## A colour per string for the chart's lines (and its bar's outline).
const STRING_COLORS := [Color(0.35, 0.75, 1.0), Color(1.0, 0.72, 0.25), Color(0.55, 0.9, 0.45),
	Color(0.95, 0.45, 0.6), Color(0.75, 0.6, 1.0), Color(0.4, 0.95, 0.85), Color(1.0, 0.95, 0.4), Color(0.9, 0.6, 0.45)]

var design: Dictionary = {}
var result: Dictionary = {}
var _sc_opt: OptionButton
var _play_btn: Button
var _scrub: HSlider
var _time_lbl: Label
var _blurb: Label
var _chart: Control
var _strings: Control
var _log: ItemList
var _summary_lbl: Label
var _now_lbl: Label
var _t := 0.0
var _playing := false
var _sc_id := "share"


func _ready() -> void:
	add_theme_constant_override("separation", 6)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 6)
	add_child(top)
	_sc_opt = OptionButton.new()
	_sc_opt.name = "bank_bench_scenario"
	_sc_opt.fit_to_longest_item = false
	_sc_opt.custom_minimum_size = Vector2(240, 0)
	_sc_opt.tooltip_text = "What the whole bank is put through"
	_sc_opt.item_selected.connect(func(i: int) -> void: run_scenario(str(_sc_opt.get_item_metadata(i))))
	top.add_child(_sc_opt)
	_play_btn = Button.new()
	_play_btn.name = "bank_bench_play"
	UiIcons.apply(_play_btn, "play", "Play the run")
	UITheme.style_button(_play_btn)
	_play_btn.pressed.connect(toggle_play)
	top.add_child(_play_btn)
	var rs := Button.new()
	rs.name = "bank_bench_restart"
	UiIcons.apply(rs, "rotate-ccw", "Back to the start")
	UITheme.style_button(rs)
	rs.pressed.connect(func() -> void: seek(0.0))
	top.add_child(rs)
	_scrub = HSlider.new()
	_scrub.name = "bank_bench_scrub"
	_scrub.min_value = 0.0
	_scrub.max_value = 1.0
	_scrub.step = 0.0005
	_scrub.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scrub.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_scrub.value_changed.connect(func(v: float) -> void: seek(v * duration()))
	top.add_child(_scrub)
	_time_lbl = Label.new()
	_time_lbl.custom_minimum_size = Vector2(140, 0)
	_time_lbl.add_theme_font_override("font", UITheme.font("regular", true))
	top.add_child(_time_lbl)
	_blurb = Label.new()
	_blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_blurb.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_blurb.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	add_child(_blurb)
	var mid := HBoxContainer.new()
	mid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	mid.add_theme_constant_override("separation", 8)
	add_child(mid)
	_chart = BenchChart.new()
	_chart.name = "bank_bench_chart"
	_chart.set("panel", self)
	_chart.custom_minimum_size = Vector2(260, 140)
	_chart.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chart.size_flags_stretch_ratio = 1.5
	mid.add_child(_chart)
	_strings = StringBars.new()
	_strings.name = "bank_bench_strings"
	_strings.set("panel", self)
	_strings.custom_minimum_size = Vector2(180, 140)
	_strings.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid.add_child(_strings)
	var side := VBoxContainer.new()
	side.custom_minimum_size = Vector2(240, 0)
	side.add_theme_constant_override("separation", 4)
	mid.add_child(side)
	_now_lbl = Label.new()
	_now_lbl.name = "bank_bench_now"
	_now_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_now_lbl.custom_minimum_size = Vector2(220, 0)
	_now_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	side.add_child(_now_lbl)
	_log = ItemList.new()
	_log.name = "bank_bench_log"
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.custom_minimum_size = Vector2(220, 60)
	_log.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_log.item_selected.connect(func(i: int) -> void: seek(float(_log.get_item_metadata(i))))
	side.add_child(_log)
	_summary_lbl = Label.new()
	_summary_lbl.name = "bank_bench_summary"
	_summary_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_summary_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	add_child(_summary_lbl)
	set_process(false)


func set_design(d: Dictionary) -> void:
	design = d
	var lithium := bool((d["pack"] as Dictionary)["lithium"])
	_sc_opt.clear()
	var keep := -1
	for sc in BankSim.scenarios_for(lithium):
		_sc_opt.add_item(str(sc["label"]))
		_sc_opt.set_item_metadata(_sc_opt.item_count - 1, str(sc["id"]))
		if str(sc["id"]) == _sc_id:
			keep = _sc_opt.item_count - 1
	if keep < 0:
		keep = 0
	_sc_opt.select(keep)
	if is_visible_in_tree():
		run_scenario(str(_sc_opt.get_item_metadata(keep)))
	else:
		result = {}


## Run a scenario on the bank and show it from the start.
func run_scenario(id: String) -> void:
	if design.is_empty():
		return
	_sc_id = id
	for i in _sc_opt.item_count:
		if str(_sc_opt.get_item_metadata(i)) == id:
			_sc_opt.select(i)
	result = BankSim.run(design, id)
	_blurb.text = str(BankSim.scenario(id)["blurb"])
	_summary_lbl.text = str(result["summary"])
	_log.clear()
	for ev in (result["events"] as Array):
		_log.add_item("%s  %s" % [BattSim.time_words(float(ev["t"])), ev["text"]])
		_log.set_item_metadata(_log.item_count - 1, float(ev["t"]))
		var c := UITheme.C_ERROR if str(ev["what"]) == "trip" else (UITheme.C_GREEN if str(ev["what"]) == "release" else UITheme.C_TEXT_S)
		_log.set_item_custom_fg_color(_log.item_count - 1, c)
	if _log.item_count == 0:
		_log.add_item("Nothing tripped.")
		_log.set_item_metadata(0, 0.0)
	_playing = false
	_set_play_icon()
	seek(0.0)


func scenario_id() -> String:
	return _sc_id


func duration() -> float:
	return float(result.get("duration_s", 0.0))


func time_s() -> float:
	return _t


func is_playing() -> bool:
	return _playing


func toggle_play() -> void:
	if result.is_empty():
		run_scenario(_sc_id)
	if _t >= duration() - 1e-9:
		_t = 0.0
	_playing = not _playing
	_set_play_icon()
	set_process(_playing)


func _set_play_icon() -> void:
	UiIcons.apply(_play_btn, "pause" if _playing else "play", "Pause" if _playing else "Play the run")


func _process(delta: float) -> void:
	if not _playing or result.is_empty():
		return
	var d := duration()
	_t = minf(d, _t + delta * d / PLAY_SECONDS)
	_show()
	if _t >= d:
		_playing = false
		_set_play_icon()
		set_process(false)


func seek(t: float) -> void:
	_t = clampf(t, 0.0, maxf(duration(), 0.0))
	_show()


func frame() -> Dictionary:
	return BankSim.frame_at(result, _t) if not result.is_empty() else {}


func _show() -> void:
	_scrub.set_value_no_signal(_t / maxf(duration(), 1e-9))
	_time_lbl.text = "%s / %s" % [BattSim.time_words(_t), BattSim.time_words(duration())]
	_chart.queue_redraw()
	_strings.queue_redraw()
	var f := frame()
	if f.is_empty():
		_now_lbl.text = ""
		return
	var lines: Array = ["Bus %.1f V · bank %s %.0f A · %.0f %% charged" % [float(f["v"]),
		"in" if float(f["i"]) >= 0.0 else "out", absf(float(f["i"])), float(f["soc"]) * 100.0]]
	if float(f["load"]) > 0.0:
		lines.append("Load %.0f A" % float(f["load"]))
	if float(f["charger"]) > 0.0:
		lines.append("Charger %.0f A%s" % [float(f["charger"]), (" (%s)" % f["stage"]) if str(f["stage"]) != "" else ""])
	var off := 0
	for c in (f["state_str"] as PackedInt32Array):
		if c != 0:
			off += 1
	if off > 0:
		lines.append("%s of %d not taking part" % [UiText.count(off, "string"), (f["state_str"] as PackedInt32Array).size()])
	if bool(result.get("comms", false)):
		lines.append("The charger hears the BMSs (comms chain)")
	_now_lbl.text = "\n".join(PackedStringArray(lines))
	frame_changed.emit(f)


## Each string's current and the bus voltage over the run.
class BenchChart extends Control:
	var panel: Control = null

	func _gui_input(e: InputEvent) -> void:
		var drag := e is InputEventMouseMotion and ((e as InputEventMouseMotion).button_mask & MOUSE_BUTTON_MASK_LEFT) != 0
		var press := e is InputEventMouseButton and (e as InputEventMouseButton).pressed and (e as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT
		if press or drag:
			var r := plot()
			var u := clampf(((e as InputEventMouse).position.x - r.position.x) / maxf(r.size.x, 1.0), 0.0, 1.0)
			panel.call("seek", u * float(panel.call("duration")))
			accept_event()

	func plot() -> Rect2:
		return Rect2(Vector2(46, 8), size - Vector2(46 + 46, 8 + 22))

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.05, 0.06, 0.09, 0.9))
		var res: Dictionary = panel.get("result")
		if res.is_empty() or (res["frames"] as Array).size() < 2:
			return
		var fr: Array = res["frames"]
		var r := plot()
		var font := UITheme.font("regular", true)
		var dur := maxf(float(res["duration_s"]), 1e-9)
		var m := int(res["parallel"])
		var vlo := INF
		var vhi := -INF
		var ilo := 0.0
		var ihi := 0.0
		for f in fr:
			vlo = minf(vlo, float(f["v"]))
			vhi = maxf(vhi, float(f["v"]))
			for a in (f["i_str"] as PackedFloat64Array):
				ilo = minf(ilo, a)
				ihi = maxf(ihi, a)
		if vhi - vlo < 0.2:
			vhi += 0.1
			vlo -= 0.1
		if ihi - ilo < 1.0:
			ihi += 0.5
			ilo -= 0.5
		for k in 5:
			var y := r.position.y + r.size.y * float(k) / 4.0
			draw_line(Vector2(r.position.x, y), Vector2(r.end.x, y), Color(1, 1, 1, 0.06))
		var y0 := r.end.y - (0.0 - ilo) / (ihi - ilo) * r.size.y
		draw_line(Vector2(r.position.x, y0), Vector2(r.end.x, y0), Color(1, 1, 1, 0.18))
		for j in mini(m, 16):
			var pts := PackedVector2Array()
			for f in fr:
				var x := r.position.x + float(f["t"]) / dur * r.size.x
				pts.append(Vector2(x, r.end.y - ((f["i_str"] as PackedFloat64Array)[j] - ilo) / (ihi - ilo) * r.size.y))
			var col: Color = STRING_COLORS[j % STRING_COLORS.size()]
			draw_polyline(pts, Color(col, 0.9), 1.5, true)
		var pv := PackedVector2Array()
		for f in fr:
			var x := r.position.x + float(f["t"]) / dur * r.size.x
			pv.append(Vector2(x, r.end.y - (float(f["v"]) - vlo) / (vhi - vlo) * r.size.y))
		draw_polyline(pv, Color(1, 1, 1, 0.75), 2.0, true)
		for ev in (res["events"] as Array):
			if str(ev["what"]) != "trip":
				continue
			var x := r.position.x + float(ev["t"]) / dur * r.size.x
			draw_line(Vector2(x, r.position.y), Vector2(x, r.end.y), Color(UITheme.C_ERROR, 0.4), 1.0)
		var px := r.position.x + float(panel.call("time_s")) / dur * r.size.x
		draw_line(Vector2(px, r.position.y), Vector2(px, r.end.y), Color(1, 1, 1, 0.8), 1.5)
		draw_string(font, Vector2(2, r.position.y + 10), "%.1f V" % vhi, HORIZONTAL_ALIGNMENT_LEFT, 44, 11, Color(1, 1, 1, 0.8))
		draw_string(font, Vector2(2, r.end.y), "%.1f V" % vlo, HORIZONTAL_ALIGNMENT_LEFT, 44, 11, Color(1, 1, 1, 0.8))
		draw_string(font, Vector2(r.end.x + 4, r.position.y + 10), "%.0f A" % ihi, HORIZONTAL_ALIGNMENT_LEFT, 44, 11, UITheme.C_TEXT_S)
		draw_string(font, Vector2(r.end.x + 4, r.end.y), "%.0f A" % ilo, HORIZONTAL_ALIGNMENT_LEFT, 44, 11, UITheme.C_TEXT_S)
		draw_string(font, Vector2(r.position.x, size.y - 6), "Bus voltage (white) · each string's current (+ in)", HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 70, 11, UITheme.C_TEXT_S)
		draw_string(font, Vector2(r.end.x - 70, size.y - 6), BattSim.time_words(dur), HORIZONTAL_ALIGNMENT_RIGHT, 70, 11, UITheme.C_TEXT_S)


## One bar per string: its charge, its current, coloured by its state.
class StringBars extends Control:
	var panel: Control = null

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.05, 0.06, 0.09, 0.9))
		var f: Dictionary = panel.call("frame")
		if f.is_empty():
			return
		var sc: PackedInt32Array = f["state_str"]
		var ss: PackedFloat64Array = f["soc_str"]
		var ii: PackedFloat64Array = f["i_str"]
		var m := sc.size()
		var font := UITheme.font("regular", true)
		var top := 16.0
		var bot := size.y - 30.0
		var w := (size.x - 8.0) / float(maxi(m, 1))
		draw_string(font, Vector2(4, 12), "Strings", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, UITheme.C_TEXT_S)
		for j in m:
			var x := 4.0 + w * float(j)
			var bw := maxf(4.0, w - 6.0)
			var h := (bot - top) * clampf(ss[j], 0.0, 1.0)
			var col := UITheme.C_GREEN
			if sc[j] == 4:
				col = Color(0.45, 0.45, 0.5)
			elif sc[j] == 3:
				col = UITheme.C_ERROR
			elif sc[j] != 0:
				col = UITheme.C_AMBER
			draw_rect(Rect2(x, top, bw, bot - top), Color(1, 1, 1, 0.05))
			draw_rect(Rect2(x, bot - h, bw, h), Color(col, 0.75))
			draw_rect(Rect2(x, top, bw, bot - top), Color(STRING_COLORS[j % STRING_COLORS.size()], 0.8), false, 1.5)
			if w > 22.0:
				draw_string(font, Vector2(x, bot + 12), "%d" % (j + 1), HORIZONTAL_ALIGNMENT_CENTER, bw, 11, UITheme.C_TEXT)
				draw_string(font, Vector2(x, bot + 25), "%.0f A" % ii[j], HORIZONTAL_ALIGNMENT_CENTER, bw, 10, UITheme.C_TEXT_S)
