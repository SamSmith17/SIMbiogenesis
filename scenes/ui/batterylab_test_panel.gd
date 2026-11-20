extends VBoxContainer

## The Battery Lab's "BMS & test" bench, under the 3D pack: pick a scenario,
## it runs at once (BattSim, cell by cell), then play or scrub it on the
## lab's own clock. Shows the pack's voltage and current over the run, a bar
## per series group against the BMS's over- and under-voltage lines (glowing
## while balancing), the two switches, the true and the counted state of
## charge, and every event. The modal owns it (`modal`) and colours the 3D
## cells from the frame shown.

signal frame_changed(frame: Dictionary)

const PLAY_SECONDS := 20.0

var modal: Control = null
var design: Dictionary = {}
var result: Dictionary = {}
var _scenario := "charge"
var _t := 0.0
var _playing := false
var _speed := 1.0

var _sc_opt: OptionButton
var _blurb: Label
var _play_btn: Button
var _speed_opt: OptionButton
var _scrub: HSlider
var _time_lbl: Label
var _chart: Chart
var _bars: Bars
var _chg_lamp: Label
var _dsg_lamp: Label
var _state_lbl: Label
var _soc_lbl: Label
var _summary_lbl: Label
var _log: ItemList


func _ready() -> void:
	add_theme_constant_override("separation", 6)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 6)
	add_child(top)
	var l := Label.new()
	l.text = "Test"
	l.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	top.add_child(l)
	_sc_opt = OptionButton.new()
	_sc_opt.name = "scenario"
	_sc_opt.fit_to_longest_item = false
	_sc_opt.custom_minimum_size = Vector2(220, 0)
	_sc_opt.item_selected.connect(func(i: int) -> void: run_scenario(str(_sc_opt.get_item_metadata(i))))
	top.add_child(_sc_opt)
	_play_btn = Button.new()
	_play_btn.name = "play"
	UiIcons.apply(_play_btn, "play", "Play the run (Space)")
	UITheme.style_button(_play_btn)
	_play_btn.pressed.connect(toggle_play)
	top.add_child(_play_btn)
	var rs := Button.new()
	rs.name = "restart"
	UiIcons.apply(rs, "rotate-ccw", "Back to the start")
	UITheme.style_button(rs)
	rs.pressed.connect(func() -> void: seek(0.0))
	top.add_child(rs)
	_speed_opt = OptionButton.new()
	_speed_opt.name = "speed"
	for sv in [[0.25, "¼×"], [1.0, "1×"], [4.0, "4×"]]:
		_speed_opt.add_item(str(sv[1]))
		_speed_opt.set_item_metadata(_speed_opt.item_count - 1, float(sv[0]))
	_speed_opt.tooltip_text = "How fast the run plays (1× = the whole run in 20 seconds)"
	_speed_opt.select(1)
	_speed_opt.item_selected.connect(func(i: int) -> void: _speed = float(_speed_opt.get_item_metadata(i)))
	top.add_child(_speed_opt)
	_scrub = HSlider.new()
	_scrub.name = "scrub"
	_scrub.min_value = 0.0
	_scrub.max_value = 1.0
	_scrub.step = 0.0005
	_scrub.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scrub.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_scrub.value_changed.connect(func(v: float) -> void: seek(v * duration()))
	top.add_child(_scrub)
	_time_lbl = Label.new()
	_time_lbl.name = "time"
	_time_lbl.custom_minimum_size = Vector2(150, 0)
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
	_chart = Chart.new()
	_chart.panel = self
	_chart.custom_minimum_size = Vector2(260, 150)
	_chart.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chart.size_flags_stretch_ratio = 1.4
	mid.add_child(_chart)
	_bars = Bars.new()
	_bars.panel = self
	_bars.custom_minimum_size = Vector2(220, 150)
	_bars.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid.add_child(_bars)
	var side := VBoxContainer.new()
	side.custom_minimum_size = Vector2(230, 0)
	side.add_theme_constant_override("separation", 4)
	mid.add_child(side)
	var lamps := HBoxContainer.new()
	lamps.add_theme_constant_override("separation", 6)
	side.add_child(lamps)
	_chg_lamp = _lamp("Charge switch")
	_chg_lamp.name = "charge_lamp"
	lamps.add_child(_chg_lamp)
	_dsg_lamp = _lamp("Discharge switch")
	_dsg_lamp.name = "discharge_lamp"
	lamps.add_child(_dsg_lamp)
	_state_lbl = Label.new()
	_state_lbl.name = "bms_state"
	_state_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_state_lbl.custom_minimum_size = Vector2(200, 0)
	_state_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	side.add_child(_state_lbl)
	_soc_lbl = Label.new()
	_soc_lbl.name = "soc"
	_soc_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_soc_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_soc_lbl.tooltip_text = "True: what the cells hold. Counted: what the BMS thinks, from its current sensor (it drifts, and resets to 100 % when it sees the pack full)."
	_soc_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	side.add_child(_soc_lbl)
	_log = ItemList.new()
	_log.name = "events"
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.custom_minimum_size = Vector2(200, 60)
	_log.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_log.item_selected.connect(func(i: int) -> void: seek(float(_log.get_item_metadata(i))))
	side.add_child(_log)
	_summary_lbl = Label.new()
	_summary_lbl.name = "summary"
	_summary_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_summary_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	add_child(_summary_lbl)
	set_process(false)


func _lamp(text: String) -> Label:
	var l := Label.new()
	l.text = "● " + text
	l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	return l


## A new design: list its scenarios and run the chosen one again.
func set_design(d: Dictionary) -> void:
	design = d
	var lithium := bool(d.get("lithium", true))
	_sc_opt.clear()
	var keep := false
	for sc in BattSim.scenarios_for(lithium):
		_sc_opt.add_item(str(sc["label"]))
		_sc_opt.set_item_metadata(_sc_opt.item_count - 1, str(sc["id"]))
		_sc_opt.set_item_tooltip(_sc_opt.item_count - 1, str(sc["blurb"]))
		if str(sc["id"]) == _scenario:
			keep = true
	if not keep:
		_scenario = "charge"
	FormRow.select_meta(_sc_opt, _scenario)
	if visible:
		run_scenario(_scenario)
	else:
		result = {}


func run_scenario(id: String) -> void:
	_scenario = id
	FormRow.select_meta(_sc_opt, id)
	if design.is_empty():
		return
	result = BattSim.run(design, id)
	_blurb.text = str(BattSim.scenario(id).get("blurb", ""))
	_summary_lbl.text = str(result.get("summary", ""))
	_log.clear()
	for ev in (result["events"] as Array):
		var c := UITheme.C_ERROR if str(ev["what"]) == "trip" else (UITheme.C_GREEN if str(ev["what"]) == "release" else UITheme.C_TEXT)
		_log.add_item("%s  %s" % [BattSim.time_words(float(ev["t"])), ev["text"]])
		_log.set_item_metadata(_log.item_count - 1, float(ev["t"]))
		_log.set_item_custom_fg_color(_log.item_count - 1, c)
		_log.set_item_tooltip(_log.item_count - 1, "%s — click to jump there" % str(ev["text"]))
	if (result["events"] as Array).is_empty():
		_log.add_item("Nothing tripped.")
		_log.set_item_metadata(0, 0.0)
	_playing = false
	_set_play_icon()
	seek(0.0)
	_chart.queue_redraw()


func scenario_id() -> String:
	return _scenario


func duration() -> float:
	return float(result.get("duration_s", 0.0))


func time_s() -> float:
	return _t


func is_playing() -> bool:
	return _playing


func toggle_play() -> void:
	if result.is_empty():
		return
	if not _playing and _t >= duration() - 1e-9:
		_t = 0.0
	_playing = not _playing
	_set_play_icon()
	set_process(_playing)


func _set_play_icon() -> void:
	UiIcons.apply(_play_btn, "pause" if _playing else "play", "Pause" if _playing else "Play the run (Space)")


func _process(delta: float) -> void:
	if not _playing or result.is_empty():
		return
	var d := duration()
	_t = minf(d, _t + delta * _speed * d / PLAY_SECONDS)
	_show()
	if _t >= d:
		_playing = false
		_set_play_icon()
		set_process(false)


func seek(t: float) -> void:
	_t = clampf(t, 0.0, maxf(duration(), 0.0))
	_show()


func frame() -> Dictionary:
	return BattSim.frame_at(result, _t) if not result.is_empty() else {}


func _show() -> void:
	var f := frame()
	_scrub.set_value_no_signal(_t / maxf(duration(), 1e-9))
	_time_lbl.text = "%s / %s" % [BattSim.time_words(_t), BattSim.time_words(duration())]
	_chart.queue_redraw()
	_bars.queue_redraw()
	if f.is_empty():
		return
	var prot := bool(design.get("protected", false))
	_paint_lamp(_chg_lamp, bool(f["chg"]), prot)
	_paint_lamp(_dsg_lamp, bool(f["dsg"]), prot)
	var i := float(f["i"])
	var doing := "resting"
	if i > 0.05:
		doing = "charging at %.1f A" % i
	elif i < -0.05:
		doing = "discharging at %.1f A" % -i
	var st := ""
	if not prot:
		st = "No BMS: nothing can disconnect it."
		if str(f.get("stage", "")) != "":
			st += " Charger: %s." % str(f["stage"])
	elif bool(f["chg"]) and bool(f["dsg"]):
		st = "Both switches closed."
	elif not bool(f["chg"]) and not bool(f["dsg"]):
		st = "Both switches open: nothing flows."
	elif not bool(f["chg"]):
		st = "Charge switch open: it can still power a load."
	else:
		st = "Discharge switch open: a charger can still fill it."
	_state_lbl.text = "%.2f V, %s. %s" % [float(f["v"]), doing, st]
	_soc_lbl.text = "Charge: %.0f %% true · %.0f %% counted by the BMS" % [float(f["soc"]) * 100.0, float(f["soc_est"]) * 100.0] if prot \
		else "Charge: %.0f %%" % (float(f["soc"]) * 100.0)
	frame_changed.emit(f)


func _paint_lamp(l: Label, closed: bool, prot: bool) -> void:
	if not prot:
		l.add_theme_color_override("font_color", UITheme.C_TEXT_S)
		l.tooltip_text = "No BMS"
		return
	l.add_theme_color_override("font_color", UITheme.C_GREEN if closed else UITheme.C_ERROR)
	l.tooltip_text = "Closed: current can flow" if closed else "Open: the BMS has stopped this direction"


## The pack's voltage (left) and current (right) over the run; click or drag
## to scrub.
class Chart extends Control:
	var panel: Control = null

	func _gui_input(e: InputEvent) -> void:
		var drag := e is InputEventMouseMotion and ((e as InputEventMouseMotion).button_mask & MOUSE_BUTTON_MASK_LEFT) != 0
		var press := e is InputEventMouseButton and (e as InputEventMouseButton).pressed and (e as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT
		if press or drag:
			var r := _plot()
			var u := clampf(((e as InputEventMouse).position.x - r.position.x) / maxf(r.size.x, 1.0), 0.0, 1.0)
			panel.call("seek", u * float(panel.call("duration")))
			accept_event()

	func _plot() -> Rect2:
		return Rect2(Vector2(46, 8), size - Vector2(46 + 46, 8 + 22))

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.05, 0.06, 0.09, 0.9))
		var res: Dictionary = panel.get("result")
		if res.is_empty():
			return
		var fr: Array = res["frames"]
		if fr.size() < 2:
			return
		var r := _plot()
		var font := UITheme.font("regular", true)
		var dur := maxf(float(res["duration_s"]), 1e-9)
		var vlo := INF
		var vhi := -INF
		var ilo := 0.0
		var ihi := 0.0
		for f in fr:
			vlo = minf(vlo, float(f["v"]))
			vhi = maxf(vhi, float(f["v"]))
			ilo = minf(ilo, float(f["i"]))
			ihi = maxf(ihi, float(f["i"]))
		if vhi - vlo < 0.2:
			vhi += 0.1
			vlo -= 0.1
		if ihi - ilo < 1.0:
			ihi += 0.5
			ilo -= 0.5
		# Grid and zero current.
		for k in 5:
			var y := r.position.y + r.size.y * float(k) / 4.0
			draw_line(Vector2(r.position.x, y), Vector2(r.end.x, y), Color(1, 1, 1, 0.06))
		var y0 := r.end.y - (0.0 - ilo) / (ihi - ilo) * r.size.y
		draw_line(Vector2(r.position.x, y0), Vector2(r.end.x, y0), Color(1, 1, 1, 0.18))
		var pv := PackedVector2Array()
		var pi := PackedVector2Array()
		for f in fr:
			var x := r.position.x + float(f["t"]) / dur * r.size.x
			pv.append(Vector2(x, r.end.y - (float(f["v"]) - vlo) / (vhi - vlo) * r.size.y))
			pi.append(Vector2(x, r.end.y - (float(f["i"]) - ilo) / (ihi - ilo) * r.size.y))
		draw_polyline(pi, Color(UITheme.C_AMBER, 0.85), 1.5, true)
		draw_polyline(pv, UITheme.C_PRIMARY, 2.0, true)
		# Events.
		for ev in (res["events"] as Array):
			var x := r.position.x + float(ev["t"]) / dur * r.size.x
			var c := UITheme.C_ERROR if str(ev["what"]) == "trip" else (UITheme.C_GREEN if str(ev["what"]) == "release" else UITheme.C_TEXT_S)
			draw_line(Vector2(x, r.position.y), Vector2(x, r.end.y), Color(c, 0.45), 1.0)
		# Playhead.
		var px := r.position.x + float(panel.call("time_s")) / dur * r.size.x
		draw_line(Vector2(px, r.position.y), Vector2(px, r.end.y), Color(1, 1, 1, 0.8), 1.5)
		# Axes.
		draw_string(font, Vector2(2, r.position.y + 10), "%.1f V" % vhi, HORIZONTAL_ALIGNMENT_LEFT, 44, 11, UITheme.C_PRIMARY)
		draw_string(font, Vector2(2, r.end.y), "%.1f V" % vlo, HORIZONTAL_ALIGNMENT_LEFT, 44, 11, UITheme.C_PRIMARY)
		draw_string(font, Vector2(r.end.x + 4, r.position.y + 10), "%.0f A" % ihi, HORIZONTAL_ALIGNMENT_LEFT, 44, 11, UITheme.C_AMBER)
		draw_string(font, Vector2(r.end.x + 4, r.end.y), "%.0f A" % ilo, HORIZONTAL_ALIGNMENT_LEFT, 44, 11, UITheme.C_AMBER)
		draw_string(font, Vector2(r.position.x, size.y - 6), "Pack voltage", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, UITheme.C_PRIMARY)
		draw_string(font, Vector2(r.position.x + 100, size.y - 6), "Current (+ in)", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, UITheme.C_AMBER)
		draw_string(font, Vector2(r.end.x - 80, size.y - 6), BattSim.time_words(dur), HORIZONTAL_ALIGNMENT_RIGHT, 80, 11, UITheme.C_TEXT_S)


## One bar per series group: its voltage between the BMS's under- and
## over-voltage lines, coloured by temperature, outlined while balancing.
class Bars extends Control:
	var panel: Control = null

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.05, 0.06, 0.09, 0.9))
		var res: Dictionary = panel.get("result")
		var f: Dictionary = panel.call("frame")
		if res.is_empty() or f.is_empty():
			return
		var font := UITheme.font("regular", true)
		var cv: PackedFloat64Array = f["cell_v"]
		var ct: PackedFloat64Array = f["cell_t"]
		var bal: PackedFloat64Array = f["bal"]
		var n := cv.size()
		if n == 0:
			return
		var ov := float(res["v_ov"])
		var uv := float(res["v_uv"])
		var lo := uv - (ov - uv) * 0.12
		var hi := ov + (ov - uv) * 0.12
		var r := Rect2(Vector2(40, 8), size - Vector2(48, 30))
		var w := r.size.x / float(n)
		for g in n:
			var u := clampf((cv[g] - lo) / (hi - lo), 0.0, 1.0)
			var x := r.position.x + w * float(g)
			var h := u * r.size.y
			var tcol := BattBuilder.voltage_color(clampf((ct[g] - 15.0) / 35.0, 0.0, 1.0)) if ct.size() > g else UITheme.C_PRIMARY
			var rr := Rect2(Vector2(x + w * 0.12, r.end.y - h), Vector2(w * 0.76, h))
			draw_rect(rr, tcol)
			if bal.size() > g and absf(bal[g]) > 1e-6:
				draw_rect(rr.grow(1.5), Color(1, 1, 1, 0.9), false, 1.5)
		for lv in [[ov, "OV", UITheme.C_ERROR], [uv, "UV", UITheme.C_ERROR]]:
			var y := r.end.y - (float(lv[0]) - lo) / (hi - lo) * r.size.y
			draw_dashed_line(Vector2(r.position.x, y), Vector2(r.end.x, y), Color(lv[2], 0.85), 1.0, 4.0)
			draw_string(font, Vector2(2, y + 4), "%.2f" % float(lv[0]), HORIZONTAL_ALIGNMENT_LEFT, 38, 11, lv[2])
		var spread := (BattSim._max(cv) - BattSim._min(cv)) * 1000.0
		draw_string(font, Vector2(r.position.x, size.y - 6), "Spread %.0f mV · colour = temperature · outline = balancing" % spread, HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 11, UITheme.C_TEXT_S)
