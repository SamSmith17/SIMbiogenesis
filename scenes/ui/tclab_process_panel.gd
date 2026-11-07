extends Node

## The tri-clamp designer's PROCESS mode (TC Process Lab, Phase 3): runs the
## design's process (TcProcSim) on the lab's own clock — independent of the
## world's — with play / pause / speed / restart, a whole-batch pre-run in
## frame-budgeted chunks, and a scrubbable history.
##
## It owns three columns' worth of UI the modal shows instead of the design
## ones: the scenario (left: what is loaded and how it is run), the readouts
## (right: tiles, the selected volume, events, the chart, where the heat
## went), and the transport bar under the studio. While it runs it tints
## every part by the temperature of the volume it holds.
##
## The modal calls enter / exit / design_changed / on_click; everything else
## is driven from _process. Scenario edits go back to the modal as a new
## `process` block (undoable), which restarts the run.

const ChartScript := preload("res://scenes/ui/tclab_process_chart.gd")
const ViewScript := preload("res://scenes/ui/tclab_process_view.gd")
const CardEditor := preload("res://scenes/ui/automation_card_editor.gd")
const LensScript := preload("res://scenes/ui/tclab_molecule_lens.gd")
const SAMPLE_S := 60.0
const BUDGET_US := 6000
const PRERUN_BUDGET_US := 12000   # a pre-run may take a bigger slice of the frame
const SPEEDS := [[1.0, "1×"], [10.0, "10×"], [60.0, "1 min/s"], [300.0, "5 min/s"], [900.0, "15 min/s"], [1800.0, "30 min/s"]]
const TINT_STEP_C := 25.0
const PRERUN_RATE := 900.0           # how fast the views drift while the batch is worked out

var modal: Control = null           # the TC designer (tclab_modal.gd)
var sim: TcProcSim = null
var proc: Dictionary = {}
var design: Dictionary = {}
var active := false
var playing := false
var speed := 300.0
var prerunning := false
var done_s := 0.0                   # the run is computed up to here
var history: Array = []             # [{t_h, ...}] every SAMPLE_S
var run_events: Array = []          # every event of the computed run (a seek back trims sim.events)
var sel_cv := -1
var _next_sample := 0.0
var _ui_acc := 0.0
var _tint_acc := 0.0
var _chart_acc := 0.0
var _tint_mats := {}
var _tinted: Array = []

var left_box: VBoxContainer
var right_box: VBoxContainer
var transport: HBoxContainer
var _scenario: VBoxContainer
var _tiles: GridContainer
var _tile_vals := {}
var _card: VBoxContainer
var _events: ItemList
var _chart: Control
var _heat_box: VBoxContainer
var _note: Label
var _play_btn: Button
var _time_lbl: Label
var _speed_opt: OptionButton
var _prerun_btn: Button
var _progress: Label
var view: Node3D = null              # what is inside (tclab_process_view.gd)
var view_bar: HBoxContainer
var _view_btns := {}
var _cut_opt: OptionButton
var _cut_slider: HSlider
var _readings_box: VBoxContainer
var _control_box: VBoxContainer
var _right_tabs := {}
var _sensor_vals := {}           # entity → [Label, unit]
var _act_ctrls := {}             # entity → CheckButton / SpinBox
var _card_editor: Control = null
var _auto_expanded := {}
var _editing_autos := false
var _probe_kind: OptionButton
var _yaml_note: Label
var _use_after_prerun := false
var _use_note: Label
var _use_btn: Button
var lens: Control = null             # the molecule lens (tclab_molecule_lens.gd), only while shown
var _lens_btn: CheckBox


func setup(m: Control, left_parent: Control, right_parent: Control, centre_parent: Control) -> void:
	modal = m
	left_box = VBoxContainer.new()
	left_box.name = "process_left"
	left_box.add_theme_constant_override("separation", 4)
	left_box.visible = false
	left_parent.add_child(left_box)
	right_box = VBoxContainer.new()
	right_box.name = "process_right"
	right_box.add_theme_constant_override("separation", 4)
	right_box.visible = false
	right_parent.add_child(right_box)
	transport = HBoxContainer.new()
	transport.name = "process_transport"
	transport.add_theme_constant_override("separation", 6)
	transport.visible = false
	centre_parent.add_child(transport)
	view_bar = HBoxContainer.new()
	view_bar.name = "process_view_bar"
	view_bar.add_theme_constant_override("separation", 6)
	view_bar.visible = false
	centre_parent.add_child(view_bar)
	_build_left()
	_build_right()
	_build_transport()
	_build_view_bar()
	set_process(false)


# ---------------------------------------------------------------------------
# Enter / exit
# ---------------------------------------------------------------------------

func enter(d: Dictionary) -> void:
	active = true
	left_box.visible = true
	right_box.visible = true
	transport.visible = true
	view_bar.visible = true
	if view == null:
		view = ViewScript.new()
		view.name = "ProcessView"
		var st: StudioViewport = modal.call("studio")
		st.holder.add_child(view)
		view.call("setup", modal.call("builder"), st.camera)
	set_process(true)
	design_changed(d)


func exit() -> void:
	active = false
	playing = false
	prerunning = false
	left_box.visible = false
	right_box.visible = false
	transport.visible = false
	view_bar.visible = false
	set_process(false)
	_clear_tint()
	set_lens(false)
	if view != null:
		view.get_parent().remove_child(view)
		view.queue_free()
		view = null


## The design (or its process block) changed: start the run again.
func design_changed(d: Dictionary) -> void:
	var new_proc := TcProcSpec.resolve((d.get("spec", {}) as Dictionary).get("process", {}))
	if sim != null and _same_run(d, new_proc):
		# Only the fitted recipe changed: the run stands.
		design = d
		proc = new_proc
		if view != null and active:
			view.set("builder", modal.call("builder"))
			view.call("apply_mode")
		_apply_tint()
		_refresh_use()
		return
	design = d
	proc = new_proc
	sim = TcProcSim.create(d, proc)
	done_s = 0.0
	history = []
	run_events = []
	_next_sample = 0.0
	playing = false
	prerunning = false
	_record()
	if sel_cv >= sim.n_cv:
		sel_cv = -1
	if sel_cv < 0:
		sel_cv = sim.vessel_cv
	_rebuild_scenario()
	_refresh_use()
	if not _editing_autos:
		_rebuild_control()
	if view != null and active:
		view.set("builder", modal.call("builder"))
		view.set("pivot_cv", sel_cv)
		view.call("rebuild", sim, d)
	if lens != null:
		lens.call("show_cv", sim, sel_cv if sel_cv >= 0 else sim.vessel_cv)
	_refresh_all()


## Whether a new process block runs the same as the current one (the
## geometry and everything but the fitted recipe unchanged).
func _same_run(d: Dictionary, new_proc: Dictionary) -> bool:
	if design.is_empty() or TcSpec.key_of(d.get("spec", {}) as Dictionary) != TcSpec.key_of(design.get("spec", {}) as Dictionary):
		return false
	var a := proc.duplicate(true)
	var b := new_proc.duplicate(true)
	a.erase("recipe")
	b.erase("recipe")
	return TcProcSpec.key_of(a) == TcProcSpec.key_of(b)


func is_running() -> bool:
	return playing or prerunning


# ---------------------------------------------------------------------------
# API (harness / modal)
# ---------------------------------------------------------------------------

func play(on: bool = true) -> void:
	playing = on
	if on:
		prerunning = false
	_sync_transport()


func set_speed(mult: float) -> void:
	speed = maxf(mult, 0.1)
	for i in SPEEDS.size():
		if absf(float(SPEEDS[i][0]) - speed) < 1e-6:
			_speed_opt.select(i)


## Compute the whole batch (proc.duration_h) in frame-budgeted chunks.
func prerun_batch() -> void:
	prerunning = true
	playing = false
	_sync_transport()


## Show the run at t (hours): seek back within the computed run, or run on
## to it.
func seek_h(t_h: float) -> void:
	var t := clampf(t_h, 0.0, float(proc["duration_h"])) * 3600.0
	if t <= sim.t_s or t <= done_s:
		sim.seek(t)
	else:
		_advance(t, 1 << 30)
	_refresh_all()


func time_h() -> float:
	return sim.t_s / 3600.0 if sim != null else 0.0


func readings() -> Dictionary:
	return sim.readings() if sim != null else {}


func select_cv(i: int) -> void:
	if view != null:
		view.set("pivot_cv", i)
	if lens != null and sim != null and i >= 0:
		lens.call("show_cv", sim, i)
	sel_cv = i
	_refresh_card()


# ---------------------------------------------------------------------------
# Clock
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	if not active or sim == null:
		return
	var end := float(proc["duration_h"]) * 3600.0
	if prerunning:
		var resume := sim.t_s if sim.t_s < done_s else 0.0
		if done_s < end:
			if sim.t_s < done_s:
				sim.seek(done_s)
			_advance(end, PRERUN_BUDGET_US)
		if done_s >= end - 1e-6:
			prerunning = false
			sim.seek(resume)
			_sync_transport()
			if _use_after_prerun:
				_use_after_prerun = false
				use_run()
		_progress.text = "Running the batch… %d %%" % int(done_s / end * 100.0) if prerunning else ""
	elif playing:
		var target := minf(sim.t_s + delta * speed, end)
		_advance(target, BUDGET_US)
		if sim.t_s >= end - 1e-6:
			playing = false
			_sync_transport()
	_ui_acc += delta
	_tint_acc += delta
	_chart_acc += delta
	if _ui_acc >= 0.12:
		_ui_acc = 0.0
		_refresh_tiles()
		_refresh_card()
		if _control_box.visible:
			_refresh_control()
		_time_lbl.text = _fmt_t(sim.t_s)
	if _tint_acc >= 0.4:
		_tint_acc = 0.0
		_apply_tint()
	if _chart_acc >= 0.5:
		_chart_acc = 0.0
		_refresh_chart()
		_refresh_events()
	(_chart as Object).call("set_playhead", sim.t_s / 3600.0)
	if view != null:
		view.call("update_view", delta, playing or prerunning, PRERUN_RATE if prerunning else speed)
	if lens != null:
		_place_lens()
		lens.call("update_lens", delta, playing and not prerunning, speed)


## Step the sim to `target` (s) or until `budget_us` is spent, sampling the
## history past what was computed before.
func _advance(target: float, budget_us: int) -> void:
	var t0 := Time.get_ticks_usec()
	while sim.t_s < target - 1e-9:
		sim.step(minf(TcProcSim.DT_DEFAULT, target - sim.t_s))
		if sim.t_s > done_s:
			done_s = sim.t_s
			if sim.events.size() > run_events.size():
				run_events = sim.events.duplicate(true)
			if sim.t_s >= _next_sample - 1e-6:
				_record()
		if Time.get_ticks_usec() - t0 > budget_us:
			break


func _record() -> void:
	var r := sim.readings()
	var ckg := 0.0
	for k in (r.get("condensate_total", {}) as Dictionary).keys():
		ckg += float(r["condensate_total"][k])
	var et: Array = r.get("element_t_c", [])
	var emax := 0.0
	for v in et:
		emax = maxf(emax, float(v))
	history.append({"t_h": sim.t_s / 3600.0, "bed_max": float(r.get("bed_t_max_c", NAN)), "bed_mean": float(r.get("bed_t_mean_c", NAN)),
		"vessel": float(r.get("vessel_t_c", NAN)), "element": emax, "p": float(r.get("vessel_p_kpa_g", 0.0)),
		"gas": float(r.get("gas_out_l_min", 0.0)), "gas_dry": float(r.get("gas_out_dry_l_min", 0.0)),
		"lhv": float(r.get("gas_lhv_mj_nm3", 0.0)), "cond": ckg, "char": float(r.get("char_kg", 0.0)),
		"moisture": float(r.get("moisture_kg", 0.0)), "e_kwh": float(r.get("energy_in_kwh", 0.0))})
	_next_sample = sim.t_s + SAMPLE_S


# ---------------------------------------------------------------------------
# Scenario (left)
# ---------------------------------------------------------------------------

func _build_left() -> void:
	left_box.add_child(SectionHeader.make("Process", "flame", "what is loaded and how it is run"))
	_scenario = VBoxContainer.new()
	_scenario.name = "scenario"
	_scenario.add_theme_constant_override("separation", 3)
	left_box.add_child(_scenario)
	_note = Label.new()
	_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_note.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_note.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	left_box.add_child(_note)


func _clear(box: Node) -> void:
	for c in box.get_children():
		box.remove_child(c)
		c.queue_free()


func _rebuild_scenario() -> void:
	_clear(_scenario)
	var ch: Dictionary = proc["charge"]
	_scenario.add_child(SectionHeader.make("Charge", "package"))
	var feeds: Array = []
	for k in TcProcSpec.FEEDS.keys():
		feeds.append([k, str(TcProcSpec.FEEDS[k]["label"])])
	var feed_row := FormRow.option("Load", feeds, func(v: Variant) -> void: _edit(["charge", "feed"], str(v)),
		"What goes in the vessel", "proc_feed")
	FormRow.select_meta(feed_row.control as OptionButton, str(ch["feed"]))
	_scenario.add_child(feed_row)
	var mass := FormRow.spin("Mass", 0.5, 500.0, 0.5, " kg", func(v: float) -> void: _edit(["charge", "mass_kg"], v),
		"Wet mass loaded", "proc_mass")
	mass.set_value(float(ch["mass_kg"]))
	_scenario.add_child(mass)
	var fd: Dictionary = TcProcSpec.FEEDS.get(str(ch["feed"]), {})
	if (fd.get("solid", {}) as Dictionary).has("cellulose"):
		var moist := FormRow.slider("Moisture", 0.0, 60.0, float(ch["moisture"]) * 100.0, 1.0, " %",
			func(v: float) -> void: _edit(["charge", "moisture"], v / 100.0), "Water in the wood, as a share of its wet mass", "proc_moisture")
		_scenario.add_child(moist)
	_scenario.add_child(SectionHeader.make("Heating", "zap"))
	if sim.heater_parts.is_empty():
		_scenario.add_child(_muted("No heating element on the vessel: add one from the palette."))
	for pid in sim.heater_parts:
		var hs := TcProcSpec.heater(proc, str(pid))
		var w := FormRow.spin(_part_label(str(pid)), 0.0, 6000.0, 50.0, " W", func(v: float) -> void:
			_edit(["heaters", "by_part", str(pid)], {"w": v, "on": bool(TcProcSpec.heater(proc, str(pid))["on"])}),
			"This element's power", "proc_w_%s" % pid)
		w.set_value(float(hs["w"]))
		_scenario.add_child(w)
	_scenario.add_child(SectionHeader.make("Cooling water", "droplet"))
	var cool: Dictionary = proc["cooling"]
	var tc := FormRow.spin("Inlet", 0.0, 90.0, 1.0, " °C", func(v: float) -> void: _edit(["cooling", "t_c"], v),
		"The water fed to every condenser jacket", "proc_cool_t")
	tc.set_value(float(cool["t_c"]))
	_scenario.add_child(tc)
	var lpm := FormRow.spin("Flow", 0.0, 50.0, 0.1, " L/min", func(v: float) -> void: _edit(["cooling", "lpm"], v),
		"Through each condenser jacket", "proc_cool_lpm")
	lpm.set_value(float(cool["lpm"]))
	_scenario.add_child(lpm)
	_scenario.add_child(SectionHeader.make("Vessel and room", "house"))
	var fill := FormRow.option("Jacket gap", [["air", "Air"], ["insulation", "Packed with insulation"]],
		func(v: Variant) -> void: _edit(["jacket_fill"], str(v)), "An air gap loses far more heat at temperature", "proc_jacket")
	FormRow.select_meta(fill.control as OptionButton, str(proc.get("jacket_fill", "air")))
	_scenario.add_child(fill)
	var amb := FormRow.spin("Room", -30.0, 50.0, 1.0, " °C", func(v: float) -> void: _edit(["ambient_c"], v), "", "proc_ambient")
	amb.set_value(float(proc["ambient_c"]))
	_scenario.add_child(amb)
	var rel := FormRow.spin("Relief set", 0.05, 10.0, 0.05, " bar", func(v: float) -> void: _edit(["relief_bar"], v),
		"Where a relief valve on the design lifts (gauge)", "proc_relief")
	rel.set_value(float(proc["relief_bar"]))
	_scenario.add_child(rel)
	var back := FormRow.spin("Outlet back-pressure", 0.0, 200.0, 0.5, " kPa", func(v: float) -> void: _edit(["back_kpa"], v),
		"What the gas outlet pushes against (gauge)", "proc_back")
	back.set_value(float(proc["back_kpa"]))
	_scenario.add_child(back)
	var dur := FormRow.spin("Batch length", 0.5, 48.0, 0.5, " h", func(v: float) -> void: _edit(["duration_h"], v),
		"How long a run lasts", "proc_duration")
	dur.set_value(float(proc["duration_h"]))
	_scenario.add_child(dur)
	_note.text = _scenario_note()


func _scenario_note() -> String:
	if sim.vessel_cv < 0:
		return "This design has no vessel, so nothing happens in it. Load the biochar reactor, the plastic retort, the pot still or the brew kettle."
	var bits: Array = []
	if sim.bed != null and not sim.bed.is_empty():
		bits.append("%.0f mm deep round %s." % [sim.bed.height_m * 1000.0, UiText.count(sim.bed.domains.size(), "element")])
	var outs := 0
	for b in sim.net["boundaries"]:
		if str(b["role"]) in ["product", "atmosphere", "outlet"]:
			outs += 1
	var burners := 0
	for u in sim.units:
		if str(u["kind"]) in ["engine", "flare", "holder"]:
			burners += 1
	if outs == 0 and burners == 0:
		bits.append("Nothing lets gas out: the vessel will pressurise. Label an outlet or fit a relief valve.")
	elif outs == 0:
		bits.append("The gas goes to the process units on the line (a holder, genset or flare).")
	return " ".join(bits)


func _muted(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	l.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	return l


func _part_label(pid: String) -> String:
	var pd: Dictionary = (design.get("res", {}) as Dictionary).get("parts", {}).get(pid, {})
	return "%s (%s)" % [str((pd.get("built", {}) as Dictionary).get("label", pid)), pid]


## Write one value into the process block and hand it to the modal.
func _edit(path: Array, v: Variant) -> void:
	var p := proc.duplicate(true)
	var d: Dictionary = p
	for i in range(path.size() - 1):
		var k: String = path[i]
		if not (d.get(k) is Dictionary):
			d[k] = {}
		d = d[k]
	d[str(path[-1])] = v
	if modal != null and modal.has_method("set_process_block"):
		modal.call("set_process_block", p)


# ---------------------------------------------------------------------------
# Readouts (right)
# ---------------------------------------------------------------------------

const TILES := [
	["bed_max", "Hottest charge", "°C"], ["vessel", "Vessel gas", "°C"],
	["pressure", "Pressure", "kPa"], ["element", "Elements", "°C"],
	["dry_front", "Drying front", "mm"], ["pyro_front", "Char front", "mm"],
	["gas", "Gas out", "L/min"], ["lhv", "Gas LHV", "MJ/Nm³"],
	["cond", "Condensate", "kg"], ["char", "Char", "kg"],
	["energy", "Energy in", "kWh"], ["cool", "Cooling out", "°C"],
]


func _build_right() -> void:
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 4)
	right_box.add_child(tabs)
	for t in [["readings", "Readings", "What the process is doing now and over the batch"],
			["control", "Control", "Sensors, switches and the automations that run the batch"]]:
		var b := Button.new()
		b.name = "right_%s" % str(t[0])
		b.text = str(t[1])
		b.toggle_mode = true
		b.button_pressed = str(t[0]) == "readings"
		b.tooltip_text = str(t[2])
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.style_button(b)
		b.pressed.connect(func() -> void: show_right(str(t[0])))
		tabs.add_child(b)
		_right_tabs[str(t[0])] = b
	_readings_box = VBoxContainer.new()
	_readings_box.name = "readings_box"
	_readings_box.add_theme_constant_override("separation", 4)
	right_box.add_child(_readings_box)
	_control_box = VBoxContainer.new()
	_control_box.name = "control_box"
	_control_box.add_theme_constant_override("separation", 4)
	_control_box.visible = false
	right_box.add_child(_control_box)
	var rb := _readings_box
	rb.add_child(SectionHeader.make("Now", "gauge"))
	_tiles = GridContainer.new()
	_tiles.name = "tiles"
	_tiles.columns = 2
	_tiles.add_theme_constant_override("h_separation", 6)
	_tiles.add_theme_constant_override("v_separation", 6)
	rb.add_child(_tiles)
	for t in TILES:
		var p := PanelContainer.new()
		p.add_theme_stylebox_override("panel", UITheme.card_style())
		p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 0)
		var cap := Label.new()
		cap.text = str(t[1])
		cap.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		cap.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		v.add_child(cap)
		var val := Label.new()
		val.name = "tile_%s" % str(t[0])
		val.text = "—"
		val.add_theme_font_override("font", UITheme.font("semibold", true))
		val.add_theme_font_size_override("font_size", UITheme.FONT_LG)
		v.add_child(val)
		p.add_child(v)
		_tiles.add_child(p)
		_tile_vals[str(t[0])] = val
	rb.add_child(SectionHeader.make("Selected volume", "target", "click a part"))
	_card = VBoxContainer.new()
	_card.name = "cv_card"
	_card.add_theme_constant_override("separation", 2)
	rb.add_child(_card)
	rb.add_child(SectionHeader.make("Over the batch", "trending-up"))
	_chart = ChartScript.new()
	_chart.name = "chart"
	_chart.custom_minimum_size = Vector2(0, 260)
	_chart.connect("scrubbed", func(t_h: float) -> void: seek_h(t_h))
	rb.add_child(_chart)
	rb.add_child(SectionHeader.make("What happened", "list"))
	_events = ItemList.new()
	_events.name = "events"
	_events.auto_height = true
	_events.custom_minimum_size = Vector2(0, 80)
	_events.item_selected.connect(func(i: int) -> void:
		var e: Dictionary = _events.get_item_metadata(i)
		seek_h(float(e["t_s"]) / 3600.0))
	rb.add_child(_events)
	rb.add_child(SectionHeader.make("Where the heat went", "flame"))
	_heat_box = VBoxContainer.new()
	_heat_box.add_theme_constant_override("separation", 2)
	rb.add_child(_heat_box)
	rb.add_child(SectionHeader.make("In the world", "globe", "the graph runs a summary"))
	_use_btn = Button.new()
	_use_btn.name = "proc_use_run"
	_use_btn.text = "Use this run on the graph"
	_use_btn.tooltip_text = "Fit this batch into a recipe for the reactor's graph node: what goes in, what comes out and when, the power it draws, the gas's heating value"
	UITheme.style_button(_use_btn)
	_use_btn.pressed.connect(use_run)
	rb.add_child(_use_btn)
	_use_note = _muted("")
	_use_note.name = "use_note"
	rb.add_child(_use_note)


# ---------------------------------------------------------------------------
# Control (Phase 5b): sensors, switches, automations
# ---------------------------------------------------------------------------

func show_right(which: String) -> void:
	for k in _right_tabs.keys():
		(_right_tabs[k] as Button).set_pressed_no_signal(str(k) == which)
	_readings_box.visible = which == "readings"
	_control_box.visible = which == "control"
	if which == "control":
		_refresh_control()


func _rebuild_control() -> void:
	_clear(_control_box)
	_sensor_vals = {}
	_act_ctrls = {}
	_card_editor = null
	if sim == null:
		return
	var box := _control_box
	box.add_child(SectionHeader.make("Sensors", "gauge", "what the rules can read"))
	var grid := GridContainer.new()
	grid.name = "sensor_list"
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	box.add_child(grid)
	for e in sim.control_sensors:
		var l := Label.new()
		l.text = str(e["label"])
		l.tooltip_text = str(e["key"])
		l.mouse_filter = Control.MOUSE_FILTER_PASS
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.clip_text = true
		l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		l.add_theme_color_override("font_color", UITheme.C_TEXT_S)
		grid.add_child(l)
		var v := Label.new()
		v.name = "sv_%s" % str(e["key"]).replace(".", "_")
		v.add_theme_font_override("font", UITheme.font("medium", true))
		v.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		grid.add_child(v)
		_sensor_vals[str(e["key"])] = [v, str(e.get("unit", ""))]
	# Probes the player drops on a volume.
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	box.add_child(row)
	_probe_kind = OptionButton.new()
	_probe_kind.name = "probe_kind"
	for i in TcProcControl.PROBE_KINDS.size():
		_probe_kind.add_item(str(TcProcControl.PROBE_KINDS[i][1]), i)
	_probe_kind.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_probe_kind)
	var add := Button.new()
	add.name = "proc_add_probe"
	add.text = "Add probe"
	add.tooltip_text = "A probe on the selected volume (click a part first): it becomes a sensor the rules can read"
	UITheme.style_button(add)
	add.pressed.connect(add_probe)
	row.add_child(add)
	var probes: Array = proc.get("sensors", [])
	for pi in probes.size():
		var pr: Dictionary = probes[pi]
		var pr_row := HBoxContainer.new()
		var pl := _muted("Probe “%s” on %s" % [str(pr.get("name", "")), _part_label(str(pr.get("part", "")))])
		pl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pr_row.add_child(pl)
		var idx: int = pi
		var rm := IconButton.make("trash-2", "Remove this probe", func() -> void:
			var a: Array = (proc.get("sensors", []) as Array).duplicate(true)
			if idx < a.size():
				a.remove_at(idx)
			_edit(["sensors"], a))
		pr_row.add_child(rm)
		box.add_child(pr_row)
	# Switches and numbers (by hand, for this run from now).
	box.add_child(SectionHeader.make("Switches", "sliders-horizontal", "by hand, from now"))
	for a in sim.control_acts:
		var key := str(a["key"])
		if str(a["kind"]) == "switch":
			var cb := CheckButton.new()
			cb.name = "act_%s" % key.replace(".", "_")
			cb.text = str(a["label"])
			cb.tooltip_text = key
			cb.add_theme_font_size_override("font_size", UITheme.FONT_XS)
			cb.button_pressed = TcProcControl.is_on(sim, str(a["act"]))
			cb.toggled.connect(func(on: bool) -> void: _manual(key, "turn_on" if on else "turn_off", 0.0))
			box.add_child(cb)
			_act_ctrls[key] = cb
		else:
			var nr := HBoxContainer.new()
			var nl := Label.new()
			nl.text = str(a["label"])
			nl.tooltip_text = key
			nl.mouse_filter = Control.MOUSE_FILTER_PASS
			nl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			nl.clip_text = true
			nl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			nl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
			nr.add_child(nl)
			var sp := SpinBox.new()
			sp.name = "act_%s" % key.replace(".", "_")
			sp.min_value = float(a.get("min", 0.0))
			sp.max_value = float(a.get("max", 100.0))
			sp.step = float(a.get("step", 1.0))
			sp.suffix = str(a.get("unit", ""))
			sp.value = TcProcControl.value_of(sim, a)
			sp.custom_minimum_size = Vector2(110, 0)
			sp.value_changed.connect(func(v: float) -> void: _manual(key, "set_value", v))
			nr.add_child(sp)
			box.add_child(nr)
			_act_ctrls[key] = sp
	# Automations.
	box.add_child(SectionHeader.make("Automations", "zap", "run in the model"))
	_card_editor = CardEditor.new()
	_card_editor.name = "automation_cards"
	_card_editor.set("auto_rebuild", true)
	_card_editor.set("show_ab", false)
	_card_editor.set("show_push", false)
	_card_editor.set("expanded", _auto_expanded)
	_card_editor.set("empty_hint", "No automations yet. Pick a preset (hold the charge at a temperature, empty a trap when it fills…) or build a rule.")
	box.add_child(_card_editor)
	_card_editor.call("setup", proc.get("automations", []), _provider())
	_card_editor.connect("automations_changed", func(autos: Array) -> void:
		_editing_autos = true
		_edit(["automations"], autos)
		_editing_autos = false)
	var yb := Button.new()
	yb.name = "proc_ha_yaml"
	yb.text = "Copy as Home Assistant YAML"
	yb.tooltip_text = "The rules as automations.yaml, with this design's sensor / switch / number entities"
	UITheme.style_button(yb)
	yb.pressed.connect(func() -> void: export_yaml())
	box.add_child(yb)
	_yaml_note = _muted("")
	box.add_child(_yaml_note)
	_refresh_control()


func _provider() -> Dictionary:
	var numeric: Array = []
	for e in sim.control_sensors:
		numeric.append({"label": "%s (%s)" % [str(e["label"]), str(e.get("unit", ""))], "key": str(e["key"])})
	var states: Array = []
	var targets: Array = [{"label": "Every element", "key": ""}]
	var settable: Array = []
	for a in sim.control_acts:
		if str(a["kind"]) == "switch":
			states.append({"label": str(a["label"]), "key": str(a["key"])})
			targets.append({"label": str(a["label"]), "key": str(a["key"])})
		else:
			settable.append({"label": str(a["label"]), "key": str(a["key"]), "min": a.get("min", 0.0),
				"max": a.get("max", 100.0), "step": a.get("step", 1.0), "unit": str(a.get("unit", ""))})
	return {"numeric": func() -> Array: return numeric, "states": func() -> Array: return states,
		"targets": func() -> Array: return targets, "settable": func() -> Array: return settable,
		"numeric_default": str(numeric[0]["key"]) if not numeric.is_empty() else "",
		"action_labels": {"scene_node": "Switch on / off", "set_value": "Set a value", "delay": "Wait (seconds)"},
		"templates": TcProcControl.templates(sim, design)}


func _refresh_control() -> void:
	if sim == null:
		return
	var vals := TcProcControl.read_all(sim, sim.control_sensors)
	for k in _sensor_vals.keys():
		var e: Array = _sensor_vals[k]
		var v: Variant = vals.get(k, null)
		(e[0] as Label).text = ("%s %s" % [_fmt_num(float(v)), str(e[1])]) if v != null else "—"
	for a in sim.control_acts:
		var c: Variant = _act_ctrls.get(str(a["key"]), null)
		if c is CheckButton:
			(c as CheckButton).set_pressed_no_signal(TcProcControl.is_on(sim, str(a["act"])))
		elif c is SpinBox and not (c as SpinBox).get_line_edit().has_focus():
			(c as SpinBox).set_value_no_signal(TcProcControl.value_of(sim, a))


static func _fmt_num(v: float) -> String:
	if absf(v) >= 100.0:
		return "%d" % int(round(v))
	if absf(v) >= 10.0:
		return "%.1f" % v
	return "%.2f" % v


## A switch or a number by hand: applied to the run from now and logged; the
## run beyond now no longer holds, so it is worked out again from here.
func _manual(key: String, cmd: String, v: float) -> void:
	if sim == null:
		return
	var base_w := {}
	for pid in sim.heater_parts:
		base_w[str(pid)] = float(TcProcSpec.heater(proc, str(pid))["w"])
	var c: Dictionary = {"cmd": cmd, "target": key} if cmd != "set_value" else {"cmd": "set_value", "entity_id": key, "value": v}
	var txt := TcProcControl.apply(sim, sim.control_acts, c, float((proc.get("cooling", {}) as Dictionary).get("lpm", 2.0)), base_w)
	if txt == "":
		return
	sim.events.append({"t_s": sim.t_s, "id": "manual", "text": "By hand: %s." % txt})
	# Keyframes past now describe a run without this change.
	var keep: Array = []
	for k in sim.keyframes:
		if float(k["t_s"]) <= sim.t_s + 1e-6:
			keep.append(k)
	sim.keyframes = keep
	sim._next_key = (floor(sim.t_s / TcProcSim.KEYFRAME_S) + 1.0) * TcProcSim.KEYFRAME_S
	done_s = sim.t_s
	run_events = sim.events.duplicate(true)
	var hk: Array = []
	for h in history:
		if float(h["t_h"]) * 3600.0 <= sim.t_s + 1e-6:
			hk.append(h)
	history = hk
	_next_sample = sim.t_s + SAMPLE_S
	_refresh_events()
	_refresh_control()


## Drop a probe of the chosen kind on the selected volume.
func add_probe() -> void:
	if sim == null:
		return
	var i := sel_cv if sel_cv >= 0 else sim.vessel_cv
	if i < 0:
		return
	var parts: Array = sim.net["cvs"][i]["parts"]
	if parts.is_empty():
		return
	var k := maxi(_probe_kind.selected, 0)
	var kind := str(TcProcControl.PROBE_KINDS[k][0])
	var a: Array = (proc.get("sensors", []) as Array).duplicate(true)
	a.append({"name": "%s %s" % [str(TcProcControl.PROBE_KINDS[k][1]).get_slice(" ", 0).to_lower(), str(parts[0])],
		"kind": kind, "part": str(parts[0])})
	_edit(["sensors"], a)


## Fit the whole batch into a recipe and put it on the design (and on the
## placed reactor's graph node when the designer was opened on one). Works
## the batch out first when it is not done yet.
func use_run() -> void:
	if sim == null:
		return
	var end := float(proc["duration_h"]) * 3600.0
	if done_s < end - 1e-6:
		_use_after_prerun = true
		_use_note.text = "Working out the whole batch first…"
		prerun_batch()
		return
	var resume := sim.t_s
	sim.seek(done_s)
	var preset := TcDesign.bound_preset(design.get("spec", {}) as Dictionary)
	var ps: Dictionary = preset.get("specs", {}) as Dictionary
	var recipe := TcProcSummary.fit(design, proc, sim, history, run_events,
		ps.get("inputs", []) as Array, ps.get("outputs", []) as Array)
	sim.seek(resume)
	_edit(["recipe"], recipe)
	var node := ""
	if modal != null and modal.has_method("write_recipe_to_bound"):
		node = str(modal.call("write_recipe_to_bound"))
	_refresh_use(node)


func _refresh_use(node: String = "") -> void:
	if _use_note == null:
		return
	var r: Dictionary = proc.get("recipe", {})
	if r.is_empty():
		_use_note.text = "A placed reactor's node runs a fixed guess until you use a run here."
		return
	var sm: Dictionary = r.get("tc_summary", {})
	var where := "On %s's graph node now." % node if node != "" else "Saved on the design: a reactor placed from it (or Apply) runs this batch."
	var lab: Array = []
	if not (proc.get("automations", []) as Array).is_empty():
		lab = TcProcSummary.world_automations(proc.get("automations", []))["lab_only"]
	_use_note.text = "Batch %.1f h at %s: %.1f kg in → %.2f kg char, %.2f m³ gas at %.1f MJ/m³, %.2f L wood vinegar, %.2f kg tar. %s%s" % [
		float(sm.get("batch_h", 0.0)), UiText.num(float(sm.get("watts", 0.0)), "W"), float(sm.get("feed_kg", 0.0)),
		float(sm.get("char_kg", 0.0)), float(sm.get("gas_nm3", 0.0)), float(sm.get("gas_lhv_mj_nm3", 0.0)),
		float(sm.get("vinegar_l", 0.0)), float(sm.get("tar_kg", 0.0)), where,
		(" Rules that read lab sensors stay in the lab: %s." % ", ".join(lab)) if not lab.is_empty() else ""]


## The rules as Home Assistant YAML: on the clipboard and in a file.
func export_yaml() -> String:
	var y := TcProcControl.ha_yaml(design, proc.get("automations", []))
	DisplayServer.clipboard_set(y)
	var dir := "user://tclab_designs"
	DirAccess.make_dir_recursive_absolute(dir)
	var path := "%s/%s_automations.yaml" % [dir, TcProcControl.design_slug(design)]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(y)
		f.close()
	if _yaml_note != null:
		_yaml_note.text = "Copied, and saved as %s." % path.get_file()
	return y


func _build_transport() -> void:
	_play_btn = Button.new()
	_play_btn.name = "proc_play"
	_play_btn.text = "Play"
	_play_btn.tooltip_text = "Run the process on the lab's clock (Space)"
	UITheme.style_button(_play_btn)
	_play_btn.pressed.connect(func() -> void: play(not playing))
	transport.add_child(_play_btn)
	var restart := Button.new()
	restart.name = "proc_restart"
	restart.text = "Restart"
	restart.tooltip_text = "Back to the start of the batch"
	UITheme.style_button(restart)
	restart.pressed.connect(func() -> void:
		playing = false
		seek_h(0.0)
		_sync_transport())
	transport.add_child(restart)
	_speed_opt = OptionButton.new()
	_speed_opt.name = "proc_speed"
	for i in SPEEDS.size():
		_speed_opt.add_item(str(SPEEDS[i][1]), i)
	_speed_opt.tooltip_text = "Lab seconds per real second"
	_speed_opt.item_selected.connect(func(i: int) -> void: speed = float(SPEEDS[i][0]))
	transport.add_child(_speed_opt)
	set_speed(speed)
	_time_lbl = Label.new()
	_time_lbl.name = "proc_time"
	_time_lbl.custom_minimum_size = Vector2(110, 0)
	_time_lbl.add_theme_font_override("font", UITheme.font("medium", true))
	transport.add_child(_time_lbl)
	_prerun_btn = Button.new()
	_prerun_btn.name = "proc_prerun"
	_prerun_btn.text = "Run the whole batch"
	_prerun_btn.tooltip_text = "Work out the whole batch now, then scrub through it on the chart"
	UITheme.style_button(_prerun_btn)
	_prerun_btn.pressed.connect(prerun_batch)
	transport.add_child(_prerun_btn)
	_progress = Label.new()
	_progress.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_progress.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_progress.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	transport.add_child(_progress)


func _build_view_bar() -> void:
	var lbl := _muted("Look")
	lbl.autowrap_mode = TextServer.AUTOWRAP_OFF
	lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	view_bar.add_child(lbl)
	for m in ViewScript.MODES:
		var b := Button.new()
		b.name = "view_%s" % str(m[0])
		b.text = str(m[1])
		b.toggle_mode = true
		b.button_pressed = str(m[0]) == "section"
		b.tooltip_text = {"solid": "The parts as built, tinted by how hot they are",
			"section": "Cut the assembly open: see the charge, the gas and the liquid inside",
			"xray": "See-through steel: everything inside at once"}[str(m[0])]
		UITheme.style_button(b)
		b.pressed.connect(func() -> void: set_view_mode(str(m[0])))
		view_bar.add_child(b)
		_view_btns[str(m[0])] = b
	_cut_opt = OptionButton.new()
	_cut_opt.name = "view_cut"
	for i in ViewScript.CUTS.size():
		_cut_opt.add_item(str(ViewScript.CUTS[i][1]), i)
	_cut_opt.tooltip_text = "Which way the section cuts. Facing me follows the camera; click a part to cut through it"
	_cut_opt.item_selected.connect(func(i: int) -> void:
		if view != null:
			view.call("set_cut", str(ViewScript.CUTS[i][0])))
	view_bar.add_child(_cut_opt)
	_cut_slider = HSlider.new()
	_cut_slider.name = "view_cut_offset"
	_cut_slider.min_value = -1.0
	_cut_slider.max_value = 1.0
	_cut_slider.step = 0.01
	_cut_slider.value = 0.0
	_cut_slider.custom_minimum_size = Vector2(110, 0)
	_cut_slider.tooltip_text = "Move the cut nearer or further"
	_cut_slider.value_changed.connect(func(v: float) -> void:
		if view != null:
			view.call("set_cut_offset", v))
	view_bar.add_child(_cut_slider)
	var cont := CheckBox.new()
	cont.name = "view_contents"
	cont.text = "Contents"
	cont.button_pressed = true
	cont.tooltip_text = "Draw the gas, the liquid and the charge"
	cont.toggled.connect(func(on: bool) -> void:
		if view != null:
			view.call("set_show_contents", on))
	view_bar.add_child(cont)
	_lens_btn = CheckBox.new()
	_lens_btn.name = "view_molecules"
	_lens_btn.text = "Molecules"
	_lens_btn.tooltip_text = "A close-up of the molecules in the selected volume, and the reactions the model says are happening there"
	_lens_btn.toggled.connect(set_lens)
	view_bar.add_child(_lens_btn)


## The molecule lens on / off (a picture-in-picture over the studio).
func set_lens(on: bool) -> void:
	if _lens_btn != null:
		_lens_btn.set_pressed_no_signal(on)
	if on and lens == null and active:
		lens = LensScript.new()
		lens.top_level = true
		lens.z_index = 5
		lens.set("close_requested", func() -> void: set_lens(false))
		modal.add_child(lens)
		if sim != null:
			lens.call("show_cv", sim, sel_cv if sel_cv >= 0 else sim.vessel_cv)
		_place_lens()
	elif not on and lens != null:
		lens.get_parent().remove_child(lens)
		lens.queue_free()
		lens = null


func _place_lens() -> void:
	if lens == null:
		return
	var st: StudioViewport = modal.call("studio")
	var r := st.container.get_global_rect()
	lens.global_position = Vector2(r.end.x - lens.size.x - 10.0, r.position.y + 10.0)


func set_view_mode(m: String) -> void:
	for k in _view_btns.keys():
		(_view_btns[k] as Button).set_pressed_no_signal(str(k) == m)
	_cut_opt.disabled = m != "section"
	_cut_slider.editable = m == "section"
	if view != null:
		view.call("set_mode", m)
	_apply_tint()


func _sync_transport() -> void:
	_play_btn.text = "Pause" if playing else "Play"
	_prerun_btn.disabled = prerunning


func _refresh_all() -> void:
	_sync_transport()
	_refresh_tiles()
	_refresh_card()
	_refresh_chart()
	_refresh_events()
	_time_lbl.text = _fmt_t(sim.t_s)
	_apply_tint()


static func _fmt_t(s: float) -> String:
	var m := int(s / 60.0)
	return "%d h %02d min" % [m / 60, m % 60]


func _set_tile(id: String, text: String) -> void:
	var l: Label = _tile_vals.get(id)
	if l != null and l.text != text:
		l.text = text


func _refresh_tiles() -> void:
	var r := sim.readings()
	var has_bed := r.has("bed_t_max_c")
	_set_tile("bed_max", "%.0f" % float(r["bed_t_max_c"]) if has_bed else "—")
	_set_tile("vessel", "%.0f" % float(r.get("vessel_t_c", 0.0)) if r.has("vessel_t_c") else "—")
	_set_tile("pressure", "%+.1f" % float(r.get("vessel_p_kpa_g", 0.0)))
	var et: Array = r.get("element_t_c", [])
	var es: Array = []
	for v in et:
		es.append("%.0f" % float(v))
	_set_tile("element", " / ".join(es) if not es.is_empty() else "—")
	_set_tile("dry_front", "%.0f" % float(r.get("dry_front_mm", 0.0)) if has_bed else "—")
	_set_tile("pyro_front", "%.0f" % float(r.get("pyro_front_mm", 0.0)) if has_bed else "—")
	_set_tile("gas", "%.1f" % float(r.get("gas_out_l_min", 0.0)))
	_set_tile("lhv", "%.1f" % float(r.get("gas_lhv_mj_nm3", 0.0)) if float(r.get("gas_out_dry_l_min", 0.0)) > 0.05 else "—")
	var ckg := 0.0
	for k in (r.get("condensate_total", {}) as Dictionary).keys():
		ckg += float(r["condensate_total"][k])
	_set_tile("cond", "%.2f" % ckg)
	_set_tile("char", "%.2f" % float(r.get("char_kg", 0.0)) if has_bed else "—")
	_set_tile("energy", "%.2f" % float(r.get("energy_in_kwh", 0.0)))
	var co: Array = r.get("coolant_out_c", [])
	var cmax := -INF
	for v in co:
		cmax = maxf(cmax, float(v))
	_set_tile("cool", "%.0f" % cmax if co.size() > 0 else "—")
	_refresh_heat()


func _refresh_card() -> void:
	if sim == null:
		return
	_clear(_card)
	if sel_cv < 0 or sel_cv >= sim.n_cv:
		_card.add_child(_muted("Click a part to see what is in it."))
		return
	var cv: Dictionary = sim.net["cvs"][sel_cv]
	var st := sim.cv_state(sel_cv)
	var t := Label.new()
	t.text = str(cv["label"])
	t.add_theme_font_override("font", UITheme.font("semibold"))
	t.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_card.add_child(t)
	var role := str(cv["role"])
	if role == "coolant":
		_card.add_child(FormRow.value("Water", "%.1f °C" % float(st["t_cool_c"])))
		return
	_card.add_child(FormRow.value("Gas", "%.0f °C · %+.2f kPa" % [float(st["t_gas_c"]), float(st["p_kpa_g"])]))
	_card.add_child(FormRow.value("Wall", "%.0f °C" % float(st["t_wall_c"])))
	if float(st["liquid_l"]) > 0.0005:
		var lk: Dictionary = st["liquid_kg"]
		var bits: Array = []
		for k in lk.keys():
			bits.append("%s %.2f" % [TcSpecies.display_name(str(k)).to_lower(), float(lk[k])])
		_card.add_child(FormRow.value("Liquid", "%.2f L (%s kg)" % [float(st["liquid_l"]), ", ".join(bits)]))
	var comp: Dictionary = st["composition"]
	var keys: Array = comp.keys()
	keys.sort_custom(func(a, b): return float(comp[a]) > float(comp[b]))
	for k in keys.slice(0, 6):
		var f := float(comp[k])
		if f < 0.005:
			continue
		_card.add_child(_bar(TcSpecies.display_name(str(k)), f, TcSpecies.color(str(k))))
	var rr: Dictionary = st["reactions"]
	var words: Array = []
	for k in rr.keys():
		if float(rr[k]) > 1e-6:
			words.append(str(k))
	if not words.is_empty():
		_card.add_child(_muted("Happening here: %s." % ", ".join(words)))


func _bar(label: String, frac: float, c: Color) -> Control:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = label
	l.custom_minimum_size = Vector2(130, 0)
	l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	row.add_child(l)
	var bar := ProgressBar.new()
	bar.min_value = 0.0
	bar.max_value = 1.0
	bar.value = frac
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 10)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var fill := StyleBoxFlat.new()
	fill.bg_color = c
	bar.add_theme_stylebox_override("fill", fill)
	row.add_child(bar)
	var p := Label.new()
	p.text = "%.0f %%" % (frac * 100.0)
	p.custom_minimum_size = Vector2(40, 0)
	p.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	p.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	row.add_child(p)
	return row


func _refresh_events() -> void:
	if sim == null:
		return
	# The whole computed run's events; those after the playhead are dimmed
	# (click one to jump there).
	var later := 0
	for e in run_events:
		if float(e["t_s"]) > sim.t_s + 1e-6:
			later += 1
	var sig := "%d|%d" % [run_events.size(), later]
	if str(_events.get_meta("sig", "")) == sig:
		return
	_events.set_meta("sig", sig)
	_events.clear()
	# A run of automation switches between two other events is one row (an
	# on / off rule switches every few minutes for hours).
	var run: Array = []
	for e in run_events:
		if str(e["id"]) == "auto":
			run.append(e)
			continue
		_flush_auto_run(run)
		run = []
		_add_event_row("%s  %s" % [_fmt_t(float(e["t_s"])), str(e["text"])], e, str(e["text"]))
	_flush_auto_run(run)


func _add_event_row(text: String, e: Dictionary, tip: String) -> void:
	var i := _events.add_item(text)
	_events.set_item_metadata(i, e)
	_events.set_item_tooltip(i, tip)
	if float(e["t_s"]) > sim.t_s + 1e-6:
		_events.set_item_custom_fg_color(i, UITheme.C_TEXT_M)


func _flush_auto_run(run: Array) -> void:
	if run.size() <= 2:
		for e in run:
			_add_event_row("%s  %s" % [_fmt_t(float(e["t_s"])), str(e["text"])], e, str(e["text"]))
		return
	var counts := {}
	for e in run:
		var t := str(e["text"])
		counts[t] = int(counts.get(t, 0)) + 1
	var parts: Array = []
	for t in counts.keys():
		parts.append("%s ×%d" % [str(t).trim_suffix("."), int(counts[t])])
	var first: Dictionary = run[0]
	var last: Dictionary = run[-1]
	_add_event_row("%s–%s  Automations switched %d times" % [_fmt_t(float(first["t_s"])), _fmt_t(float(last["t_s"])), run.size()],
		first, "\n".join(parts))


func _refresh_chart() -> void:
	var lanes: Array = [
		{"label": "Temp", "unit": "°C", "series": [_series("bed_max", "hottest", Color(1.0, 0.35, 0.25)),
			_series("bed_mean", "mean", Color(1.0, 0.65, 0.25)), _series("vessel", "vessel gas", Color(1.0, 0.9, 0.45))], "min": 0.0},
		{"label": "Gas", "unit": "L/min", "series": [_series("gas", "all", Color(0.85, 0.9, 1.0)),
			_series("gas_dry", "burnable + CO2", Color(0.55, 0.95, 0.55))], "min": 0.0},
		{"label": "Mass", "unit": "kg", "series": [_series("moisture", "water in", Color(0.45, 0.65, 1.0)),
			_series("char", "char", Color(0.75, 0.75, 0.75)), _series("cond", "condensate", Color(0.95, 0.70, 0.30))], "min": 0.0},
	]
	(_chart as Object).call("set_lanes", lanes, float(proc["duration_h"]), done_s / 3600.0)


func _series(key: String, label: String, c: Color) -> Dictionary:
	var pts := PackedVector2Array()
	for h in history:
		var v := float(h.get(key, NAN))
		if is_finite(v):
			pts.append(Vector2(float(h["t_h"]), v))
	return {"label": label, "color": c, "pts": pts}


func _refresh_heat() -> void:
	_clear(_heat_box)
	var lg := sim.energy_ledger()
	var e_in := maxf(float(lg["in"]), 1.0)
	if float(lg["in"]) < 1000.0:
		_heat_box.add_child(_muted("Nothing has been heated yet."))
		return
	for row in [["Held in the charge and steel", float(lg["stored"]), Color(1.0, 0.55, 0.3)],
			["Lost through the walls", float(lg["loss"]), Color(0.7, 0.7, 0.8)],
			["Carried off by cooling water", float(lg["coolant"]), Color(0.4, 0.7, 1.0)],
			["Taken by reactions", float(lg["reaction"]), Color(0.9, 0.85, 0.4)],
			["Left with the gas and liquid", float(lg["out"]), Color(0.55, 0.95, 0.55)]]:
		_heat_box.add_child(_bar(str(row[0]), clampf(float(row[1]) / e_in, 0.0, 1.0), row[2]))


# ---------------------------------------------------------------------------
# Studio: picking, the temperature tint
# ---------------------------------------------------------------------------

## A click in the studio while running: select the volume under it.
func on_click(hit: Dictionary) -> void:
	if hit.is_empty() or sim == null:
		return
	var pid := str(hit.get("id", "")).get_slice(":", 0)
	var c := TcProcNet.cv_of_part(sim.net, pid, "product")
	if c < 0:
		c = TcProcNet.cv_of_part(sim.net, pid, "main")
	if c < 0:
		c = TcProcNet.cv_of_part(sim.net, pid)
	if c < 0:
		# An attachment (an element, a gauge): the volume it sits on.
		for i in sim.n_cv:
			for a in sim.net["cvs"][i]["attach"]:
				if str(a["part"]) == pid:
					c = i
	if c >= 0:
		select_cv(c)


func _tint_for(t_c: float) -> StandardMaterial3D:
	var key := int(floor(t_c / TINT_STEP_C))
	if _tint_mats.has(key):
		return _tint_mats[key]
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = heat_color(float(key) * TINT_STEP_C)
	m.render_priority = 1
	_tint_mats[key] = m
	return m


## Cold blue → warm amber → hot red → white hot (°C).
static func heat_color(t_c: float) -> Color:
	var stops := [[15.0, Color(0.25, 0.45, 1.0, 0.0)], [60.0, Color(0.30, 0.75, 1.0, 0.30)], [100.0, Color(1.0, 0.85, 0.30, 0.38)],
		[250.0, Color(1.0, 0.55, 0.15, 0.45)], [450.0, Color(1.0, 0.20, 0.08, 0.52)], [700.0, Color(1.0, 0.85, 0.75, 0.60)]]
	if t_c <= float(stops[0][0]):
		return stops[0][1]
	for i in range(1, stops.size()):
		if t_c <= float(stops[i][0]):
			var u := (t_c - float(stops[i - 1][0])) / (float(stops[i][0]) - float(stops[i - 1][0]))
			return (stops[i - 1][1] as Color).lerp(stops[i][1], u)
	return stops[-1][1]


func _part_temp(pid: String) -> float:
	var c := TcProcNet.cv_of_part(sim.net, pid, "product")
	if c < 0:
		c = TcProcNet.cv_of_part(sim.net, pid, "main")
	if c < 0:
		for i in sim.n_cv:
			for a in sim.net["cvs"][i]["attach"]:
				if str(a["part"]) == pid:
					if str(a["role"]) == "heater":
						var et: Array = sim.element_t
						if not et.is_empty():
							return float(et[0]) - 273.15
					c = i
	if c < 0:
		return NAN
	if c == sim.vessel_cv and sim.bed != null and not sim.bed.is_empty():
		return float(sim.bed.totals()["t_mean_k"]) - 273.15
	return sim.t_wall[c] - 273.15


func _apply_tint() -> void:
	if modal == null or sim == null:
		return
	var b: Node = modal.call("builder")
	if b == null:
		return
	if view != null and str(view.get("mode")) != "solid":
		_clear_tint()
		var temps := {}
		for pid in (design.get("res", {}) as Dictionary).get("parts", {}).keys():
			temps[str(pid)] = _part_temp(str(pid))
		view.call("apply_tints", temps, heat_color)
		return
	_tinted = []
	for pid in (design.get("res", {}) as Dictionary).get("parts", {}).keys():
		var n := b.get_node_or_null("P_%s" % pid)
		if not (n is GeometryInstance3D):
			continue
		var t := _part_temp(str(pid))
		(n as GeometryInstance3D).material_overlay = _tint_for(t) if is_finite(t) else null
		_tinted.append(n)


func _clear_tint() -> void:
	for n in _tinted:
		if is_instance_valid(n):
			(n as GeometryInstance3D).material_overlay = null
	_tinted = []
