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
const MimicScript := preload("res://scenes/ui/scada/mimic_canvas.gd")
const FaceScript := preload("res://scenes/ui/scada/faceplate.gd")
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
var _tile_subs := {}
var _prerun_resume := -1.0       # where a pre-run puts the view back (-1 = the end of the batch)
var _now_rows := {}              # id → KVRow
var _batch_head: SectionHeader
var _board_note: Label
var _probe_hint: Label
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
var _view_btn: Button
var _col: DesignerColumn
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
var mimic: Control = null            # the P&ID picture (scenes/ui/scada/mimic_canvas.gd), made on first use
var pid_on := false
var _pid_btn: Button
var _mimic_doc: Dictionary = {}
var _mimic_key := ""
var _face: PanelContainer = null     # scenes/ui/scada/faceplate.gd
var _face_el: Dictionary = {}
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
	_build_left()
	_build_right()
	_build_transport()
	_build_view_bar()
	# One strip under the studio: Look / cut / contents open from "View".
	_view_btn = IconButton.make("eye", "How the assembly is drawn: solid, cut open or see-through; where the cut is; contents; the molecule lens", Callable(), "View")
	_view_btn.name = "proc_view"
	_view_btn.flat = false
	UITheme.style_button(_view_btn)
	transport.add_child(_view_btn)
	var shell: Variant = modal.get("_shell")
	if shell is DesignerShell:
		(shell as DesignerShell).add_flyout("view", view_bar, _view_btn, {"width": 760.0})
		_view_btn.pressed.connect(func() -> void: (shell as DesignerShell).toggle_flyout("view"))
	else:
		centre_parent.add_child(view_bar)
	_pid_btn = Button.new()
	_pid_btn.name = "proc_pid"
	_pid_btn.text = "P&ID"
	_pid_btn.toggle_mode = true
	_pid_btn.tooltip_text = "The process as a flat picture: pipes with what flows in them, the vessel's contents, valves and heaters you can click"
	UITheme.style_button(_pid_btn)
	_pid_btn.toggled.connect(set_pid)
	transport.add_child(_pid_btn)
	set_process(false)


# ---------------------------------------------------------------------------
# Enter / exit
# ---------------------------------------------------------------------------

func enter(d: Dictionary) -> void:
	active = true
	left_box.visible = true
	right_box.visible = true
	transport.visible = true
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
	if mimic != null:
		mimic.visible = false
	pid_on = false
	if _pid_btn != null:
		_pid_btn.set_pressed_no_signal(false)
	_hide_face()
	playing = false
	prerunning = false
	left_box.visible = false
	right_box.visible = false
	transport.visible = false
	var sh: Variant = modal.get("_shell")
	if sh is DesignerShell and (sh as DesignerShell).flyout_shown() == "view":
		(sh as DesignerShell).hide_flyout()
	set_process(false)
	_clear_tint()
	set_lens(false)
	if view != null:
		view.call("release")
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
		_refresh_board_note()
		_sync_mimic_doc()
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
	_sync_mimic_doc()
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
	for k in ["recipe", "board", "mimic"]:
		a.erase(k)
		b.erase(k)
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
	_prerun_resume = sim.t_s if sim != null and sim.t_s > 1e-6 and sim.t_s < done_s - 1.0 else -1.0
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
	if mimic != null:
		mimic.set("selected_cv", i)
		mimic.queue_redraw()
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
		# When it is done the view stays on the END of the batch (its final
		# results), or goes back to where the player had scrubbed to in a run
		# already worked out. Only Restart goes back to the start.
		var resume := _prerun_resume if _prerun_resume >= 0.0 else end
		if done_s < end:
			if sim.t_s < done_s:
				sim.seek(done_s)
			_advance(end, PRERUN_BUDGET_US)
		if done_s >= end - 1e-6:
			prerunning = false
			if absf(sim.t_s - resume) > 1e-6:
				sim.seek(resume)
			_refresh_all()
			_sync_transport()
			if _use_after_prerun:
				_use_after_prerun = false
				use_run()
		_progress.text = I18n.f("Running the batch… {end} %", {"end": "%d" % (int(done_s / end * 100.0))}) if prerunning else ""
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
		_refresh_mimic()
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
	if mimic != null and pid_on:
		_place_mimic()
		mimic.call("tick", delta, playing or prerunning, PRERUN_RATE if prerunning else speed)
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
	if outs == 0 and burners == 0 and sim._breathers.is_empty():
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

## What the batch has made and used: [id, caption, unit, what it means].
const RESULT_TILES := [
	["carbon", "Carbon locked in the char", "kg C", "The carbon held in the biochar made so far: char from wood at 450–600 °C is about 80 % carbon by mass (Lehmann & Joseph 2015)."],
	["co2e", "CO₂ kept out of the air", "kg CO₂e", "The char's carbon as CO₂, counting the 80 % of it still in the soil after 100 years (IPCC 2019 Refinement, char made at 450–600 °C). Electricity used is not netted off."],
	["char", "Biochar made", "kg", "Char in the vessel now, and its share of the dry wood loaded."],
	["gas", "Gas made", "L", "Burnable gas and CO₂ the charge has given off (normal litres, dry), wherever it went: stored, burned, vented or still in the pipes. Under it, the fuel energy in that gas."],
	["energy", "Heater electricity in", "kWh", "Electricity the heating elements have drawn so far."],
	["gen", "Generator electricity out", "kWh", "Electricity the generator has made from the gas so far, at 48 V DC."],
	["cond", "Liquids collected", "kg", "What has run out of the condenser's drains: wood vinegar (water, acids) and tar."],
	["done", "Charge converted", "%", "How much of the charge has pyrolysed. Under it, what is left of it by mass and volume."],
]
## The process right now: [id, label, what it means].
const NOW_ROWS := [
	["bed_max", "Hottest charge", "The hottest point in the charge (next to an element)."],
	["vessel", "Vessel gas", "Gas temperature and gauge pressure in the vessel's headspace."],
	["element", "Elements", "Each heating element's surface temperature."],
	["fronts", "Drying / char front", "How far out from the elements the charge has dried, and charred."],
	["gas_flow", "Gas leaving", "Gas at the labelled outlet, and its heating value."],
	["holder", "Gasometer", "How full the gas holder is."],
	["genset", "Generator", "What the generator is making now."],
	["cool", "Cooling water out", "The warmest cooling water leaving a condenser."],
]


func _build_right() -> void:
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 4)
	right_box.add_child(tabs)
	for t in [["readings", "Results", "What the batch has made and used, and what the process is doing now"],
			["control", "Control", "Rules, switches and sensors, and the controller board that makes them real"]]:
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
	_batch_head = SectionHeader.make("This batch so far", "sprout")
	rb.add_child(_batch_head)
	_tiles = GridContainer.new()
	_tiles.name = "tiles"
	_tiles.columns = 2
	_tiles.add_theme_constant_override("h_separation", 6)
	_tiles.add_theme_constant_override("v_separation", 6)
	rb.add_child(_tiles)
	for t in RESULT_TILES:
		var p := PanelContainer.new()
		p.add_theme_stylebox_override("panel", UITheme.card_style())
		p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		p.tooltip_text = str(t[3])
		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 0)
		v.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var cap := Label.new()
		cap.text = str(t[1])
		cap.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		cap.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		cap.clip_text = true
		cap.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
		v.add_child(cap)
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", 5)
		line.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var val := Label.new()
		val.name = "tile_%s" % str(t[0])
		val.text = "—"
		val.add_theme_font_override("font", UITheme.font("semibold", true))
		val.add_theme_font_size_override("font_size", UITheme.FONT_LG)
		val.mouse_filter = Control.MOUSE_FILTER_IGNORE
		line.add_child(val)
		var un := Label.new()
		un.name = "unit_%s" % str(t[0])
		un.text = str(t[2])
		un.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		un.add_theme_color_override("font_color", UITheme.C_TEXT_S)
		un.size_flags_vertical = Control.SIZE_SHRINK_END
		un.mouse_filter = Control.MOUSE_FILTER_IGNORE
		line.add_child(un)
		v.add_child(line)
		var sub := Label.new()
		sub.name = "sub_%s" % str(t[0])
		sub.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		sub.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		sub.clip_text = true
		sub.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		sub.mouse_filter = Control.MOUSE_FILTER_IGNORE
		v.add_child(sub)
		p.add_child(v)
		_tiles.add_child(p)
		_tile_vals[str(t[0])] = val
		_tile_subs[str(t[0])] = sub
	rb.add_child(SectionHeader.make("Right now", "gauge"))
	var now := VBoxContainer.new()
	now.name = "now_rows"
	now.add_theme_constant_override("separation", 1)
	rb.add_child(now)
	for t in NOW_ROWS:
		var row := KVRow.make(str(t[1]), "—", str(t[2]))
		row.name = "now_%s" % str(t[0])
		now.add_child(row)
		_now_rows[str(t[0])] = row
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
	_col = DesignerColumn.setup(rb, "tc_process", {"fold": ["Right now", "What happened", "Where the heat went"],
		"tiles": false, "finder": false})


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
	_board_note = null
	_probe_hint = null
	if sim == null:
		return
	var box := _control_box
	var intro := _muted("Rules read the sensors and flip the switches, and run inside the model as the batch plays. The last section builds the same sensors and switches as an ESP32 board for Home Assistant.")
	intro.name = "control_intro"
	box.add_child(intro)

	# 1. Rules.
	box.add_child(SectionHeader.make("Rules", "zap", "when this, then that"))
	_card_editor = CardEditor.new()
	_card_editor.name = "automation_cards"
	_card_editor.set("auto_rebuild", true)
	_card_editor.set("show_ab", false)
	_card_editor.set("show_push", false)
	_card_editor.set("expanded", _auto_expanded)
	_card_editor.set("empty_hint", "No rules yet. Pick a preset (hold the charge at a temperature, empty a trap when it fills…) or build one.")
	box.add_child(_card_editor)
	_card_editor.call("setup", proc.get("automations", []), _provider())
	_card_editor.connect("automations_changed", func(autos: Array) -> void:
		_editing_autos = true
		_edit(["automations"], autos)
		_editing_autos = false)

	# 2. Switches and numbers (by hand, for this run from now).
	box.add_child(SectionHeader.make("Switches", "sliders-horizontal", "by hand, from this moment"))
	for a in sim.control_acts:
		var key := str(a["key"])
		if str(a["kind"]) == "switch":
			var cb := CheckButton.new()
			cb.name = "act_%s" % key.replace(".", "_")
			cb.text = str(a["label"])
			cb.tooltip_text = I18n.f("{key}\nFlipping it changes the run from this moment on.", {"key": key})
			cb.add_theme_font_size_override("font_size", UITheme.FONT_SM)
			cb.clip_text = true
			cb.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			cb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			cb.button_pressed = TcProcControl.is_on(sim, str(a["act"]))
			cb.toggled.connect(func(on: bool) -> void: _manual(key, "turn_on" if on else "turn_off", 0.0))
			box.add_child(cb)
			_act_ctrls[key] = cb
		else:
			var sp := SpinBox.new()
			sp.name = "act_%s" % key.replace(".", "_")
			sp.min_value = float(a.get("min", 0.0))
			sp.max_value = float(a.get("max", 100.0))
			sp.step = float(a.get("step", 1.0))
			sp.suffix = str(a.get("unit", ""))
			sp.value = TcProcControl.value_of(sim, a)
			sp.custom_minimum_size = Vector2(118, 0)
			sp.value_changed.connect(func(v: float) -> void: _manual(key, "set_value", v))
			var nr := KVRow.make_with(str(a["label"]), sp, key)
			box.add_child(nr)
			_act_ctrls[key] = sp

	# 3. Sensors: the ones a real instrument can read, then the model's own.
	var rws := TcProcBoard.rows(sim, proc)
	box.add_child(SectionHeader.make("Sensors", "gauge", "tick = on the controller board"))
	var grid := GridContainer.new()
	grid.name = "sensor_list"
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 1)
	box.add_child(grid)
	var virt: Array = []
	for r in rws:
		if str(r["domain"]) != "sensor":
			continue
		if str(r["part"]) == "":
			virt.append(r)
			continue
		grid.add_child(_board_tick(r))
		grid.add_child(_sensor_name(r, "%s\nRead by: %s" % [str(r["key"]), str(r["note"])]))
		grid.add_child(_sensor_value(r))
	if not virt.is_empty():
		var fold := Collapsible.make("Worked out by the model (%d)" % virt.size(), false,
			"Readings with no stock sensor (how far the charge has converted, totals). Rules can use them here; on real hardware they need a Home Assistant template or a different trigger.")
		fold.name = "model_sensors"
		box.add_child(fold)
		var vg := GridContainer.new()
		vg.name = "model_list"
		vg.columns = 2
		vg.add_theme_constant_override("h_separation", 6)
		vg.add_theme_constant_override("v_separation", 1)
		fold.body.add_child(vg)
		for r2 in virt:
			vg.add_child(_sensor_name(r2, str(r2["key"])))
			vg.add_child(_sensor_value(r2))
	# Probes the player drops on a volume.
	_probe_hint = _muted("")
	_probe_hint.name = "probe_hint"
	box.add_child(_probe_hint)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	box.add_child(row)
	_probe_kind = OptionButton.new()
	_probe_kind.name = "probe_kind"
	for i in TcProcControl.PROBE_KINDS.size():
		_probe_kind.add_item(str(TcProcControl.PROBE_KINDS[i][1]), i)
	_probe_kind.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_probe_kind.tooltip_text = "What the new probe measures"
	row.add_child(_probe_kind)
	var add := Button.new()
	add.name = "proc_add_probe"
	add.text = "Add probe"
	add.tooltip_text = "Put a probe of this kind on the part you clicked in the view: it becomes a sensor the rules can read"
	UITheme.style_button(add)
	UiIcons.apply(add, "plus", "")
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
			var a2: Array = (proc.get("sensors", []) as Array).duplicate(true)
			if idx < a2.size():
				a2.remove_at(idx)
			_edit(["sensors"], a2))
		pr_row.add_child(rm)
		box.add_child(pr_row)

	# 4. The controller board.
	box.add_child(SectionHeader.make("Controller board", "cpu", "ESPHome → Home Assistant"))
	_board_note = _muted("")
	_board_note.name = "board_note"
	box.add_child(_board_note)
	var sw_fold := Collapsible.make("Switches on the board", false, "Each ticked switch gets a relay output on the board")
	sw_fold.name = "board_switches"
	box.add_child(sw_fold)
	for r3 in rws:
		if str(r3["domain"]) != "switch" or str(r3["part"]) == "":
			continue
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", 6)
		line.add_child(_board_tick(r3))
		line.add_child(_sensor_name(r3, "%s\nDriven by: %s" % [str(r3["key"]), str(r3["note"])]))
		sw_fold.body.add_child(line)
	var ob := Button.new()
	ob.name = "proc_open_esp"
	ob.text = "Open the board in the ESP designer"
	ob.tooltip_text = "An ESP32 with a part for every ticked sensor and switch, named so Home Assistant gives each the id the rules above use. Wire it, export its ESPHome YAML and flash it there."
	UITheme.style_button(ob)
	UiIcons.apply(ob, "cpu", "")
	ob.pressed.connect(open_board)
	box.add_child(ob)
	var lgb := Button.new()
	lgb.name = "proc_logic_btn"
	lgb.text = "Control blocks…"
	lgb.tooltip_text = "PID loops, on / off bands, interlocks, timers and sequences on this design's own sensors and switches. They run inside the model, every step."
	UITheme.style_button(lgb)
	UiIcons.apply(lgb, "workflow", "")
	lgb.pressed.connect(func() -> void: open_logic())
	box.add_child(lgb)
	var yb := Button.new()
	yb.name = "proc_ha_yaml"
	yb.text = "Copy the rules for Home Assistant"
	yb.tooltip_text = "The rules as automations.yaml. They name the board's entities, so they run as they are once the board is flashed and added to Home Assistant."
	UITheme.style_button(yb)
	UiIcons.apply(yb, "copy", "")
	yb.pressed.connect(func() -> void: export_yaml())
	box.add_child(yb)
	_yaml_note = _muted("")
	_yaml_note.name = "yaml_note"
	box.add_child(_yaml_note)
	_refresh_board_note()
	_refresh_control()


## The "on the board" tick of a sensor / switch row.
func _board_tick(r: Dictionary) -> CheckBox:
	var key := str(r["key"])
	var cb := CheckBox.new()
	cb.name = "board_%s" % key.replace(".", "_")
	cb.button_pressed = bool(r["on"])
	cb.tooltip_text = I18n.f("On the controller board ({note})", {"note": str(r["note"])})
	cb.toggled.connect(func(on: bool) -> void: set_on_board(key, on))
	return cb


func _sensor_name(r: Dictionary, tip: String) -> Label:
	var l := Label.new()
	l.text = str(r["label"])
	l.tooltip_text = tip
	l.mouse_filter = Control.MOUSE_FILTER_PASS
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.clip_text = true
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	l.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	return l


func _sensor_value(r: Dictionary) -> Label:
	var v := Label.new()
	v.name = "sv_%s" % str(r["key"]).replace(".", "_")
	v.add_theme_font_override("font", UITheme.font("medium", true))
	v.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	v.custom_minimum_size = Vector2(74, 0)
	_sensor_vals[str(r["key"])] = [v, str(r.get("unit", ""))]
	return v


## Put a sensor or a switch on the controller board, or take it off.
func set_on_board(key: String, on: bool) -> void:
	var cur := {}
	if proc.has("board") and proc["board"] is Dictionary and (proc["board"] as Dictionary).has("on"):
		cur = (proc["board"]["on"] as Dictionary).duplicate()
	cur[key] = on
	_edit(["board"], {"on": cur})


func _refresh_board_note() -> void:
	if _board_note == null or sim == null:
		return
	var rws := TcProcBoard.rows(sim, proc)
	var n := TcProcBoard.count_on(rws)
	var t := "One ESP32 carrying %s. Its entities get the ids the rules use (sensor.%s_…), so the rules run on the real reactor as they do here." % [
		TcProcBoard.summary(rws), TcProcControl.design_slug(design)]
	if n > TcProcBoard.MAX_PARTS:
		t += " %d parts is more than one board wires: untick some, or split them over two boards." % n
	_board_note.text = t


## The controller board in the ESP board designer, over this one.
func open_board() -> Dictionary:
	if sim == null:
		return {}
	var spec := TcProcBoard.esp_spec(design, sim, proc)
	var main: Node = modal.get_tree().current_scene if modal != null and modal.get_tree() != null else null
	if main != null and main.has_method("open_esplab"):
		main.call("open_esplab", {"spec": spec})
	return spec

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
		var txt := ("%s %s" % [_fmt_num(float(v)), str(e[1])]) if v != null else "—"
		if (e[0] as Label).text != txt:
			(e[0] as Label).text = txt
	for a in sim.control_acts:
		var c: Variant = _act_ctrls.get(str(a["key"]), null)
		if c is CheckButton:
			(c as CheckButton).set_pressed_no_signal(TcProcControl.is_on(sim, str(a["act"])))
		elif c is SpinBox and not (c as SpinBox).get_line_edit().has_focus():
			(c as SpinBox).set_value_no_signal(TcProcControl.value_of(sim, a))
	if _probe_hint != null:
		var i := sel_cv if sel_cv >= 0 else sim.vessel_cv
		var where := str(sim.net["cvs"][i]["label"]) if i >= 0 and i < sim.n_cv else "nothing"
		var ht := "New probe goes on: %s (click another part in the view to change)" % where
		if _probe_hint.text != ht:
			_probe_hint.text = ht

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


## Everything past now describes a run without the change just made.
func cut_run_here(text: String = "") -> void:
	if sim == null:
		return
	if not text.is_empty():
		sim.events.append({"t_s": sim.t_s, "id": "manual", "text": text})
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


var _logic_host: Node = null


## The control logic window on this design (scenes/ui/scada/logic_editor.gd
## over a TcLogicHost). → the window.
func open_logic(select_id: String = "") -> Node:
	if _logic_host == null or not is_instance_valid(_logic_host):
		_logic_host = Node.new()
		_logic_host.set_script(load("res://scenes/ui/scada/tc_logic_host.gd"))
		add_child(_logic_host)
		_logic_host.call("setup", self)
	_logic_host.call("refresh")
	var ed := Node.new()
	ed.set_script(load("res://scenes/ui/scada/logic_editor.gd"))
	_logic_host.add_child(ed)
	ed.call("open", _logic_host, _logic_host, select_id)
	return ed


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
	_use_note.text = I18n.f("Batch {batch_h} h at {watts}: {feed_kg} kg in → {char_kg} kg char, {gas_nm3} m³ gas at {gas_lhv_mj_nm3} MJ/m³, {vinegar_l} L wood vinegar, {tar_kg} kg tar. {where}{is_empty}", {
		"batch_h": "%.1f" % (float(sm.get("batch_h", 0.0))),
		"watts": UiText.num(float(sm.get("watts", 0.0)), "W"),
		"feed_kg": "%.1f" % (float(sm.get("feed_kg", 0.0))),
		"char_kg": "%.2f" % (float(sm.get("char_kg", 0.0))),
		"gas_nm3": "%.2f" % (float(sm.get("gas_nm3", 0.0))),
		"gas_lhv_mj_nm3": "%.1f" % (float(sm.get("gas_lhv_mj_nm3", 0.0))),
		"vinegar_l": "%.2f" % (float(sm.get("vinegar_l", 0.0))),
		"tar_kg": "%.2f" % (float(sm.get("tar_kg", 0.0))),
		"where": where,
		"is_empty": (" Rules that read lab sensors stay in the lab: %s." % ", ".join(lab)) if not lab.is_empty() else "",
	})


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
		_yaml_note.text = I18n.f("Copied, and saved as {file}. Paste it into Home Assistant's automations.yaml once the board is added.", {"file": path.get_file()})
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
	_lens_btn.tooltip_text = "A worked example of the main reaction in the selected volume, drawn molecule by molecule: what goes in, which bonds break, what comes out"
	_lens_btn.toggled.connect(set_lens)
	view_bar.add_child(_lens_btn)


# ---------------------------------------------------------------------------
# P&ID: the process as a flat picture (scenes/ui/scada/mimic_canvas.gd)
# ---------------------------------------------------------------------------

## The P&ID view on / off. It stands over the 3D studio (same transport,
## same selection, same switches); the 3D view carries on underneath.
func set_pid(on: bool) -> void:
	pid_on = on and active
	if _pid_btn != null:
		_pid_btn.set_pressed_no_signal(pid_on)
	if pid_on and mimic == null:
		mimic = Control.new()
		mimic.set_script(MimicScript)
		mimic.name = "ProcessMimic"
		mimic.top_level = true
		mimic.z_index = 2
		modal.add_child(mimic)
		mimic.connect("element_clicked", _on_mimic_element)
		mimic.connect("pipe_clicked", func(p: Dictionary) -> void:
			_hide_face()
			select_cv(int(p["cv"])))
		mimic.connect("empty_clicked", _hide_face)
		mimic.connect("element_moved", _on_mimic_moved)
		_mimic_key = ""
	if mimic != null:
		mimic.visible = pid_on
	if pid_on:
		_place_mimic()
		_sync_mimic_doc()
		_refresh_mimic()
		mimic.set("selected_cv", sel_cv)
	else:
		_hide_face()


func _place_mimic() -> void:
	var st: StudioViewport = modal.call("studio")
	var xf := st.container.get_global_transform()
	var sz := st.container.size * xf.get_scale()
	if mimic.global_position != xf.origin:
		mimic.global_position = xf.origin
	if mimic.size != sz:
		mimic.size = sz
	if _face != null and _face.visible and not _face_el.is_empty():
		_face.call("place", mimic.global_position + (mimic.call("element_rect", _face_el) as Rect2).get_center())


## Build the picture when the design changed; always take the saved pins.
func _sync_mimic_doc() -> void:
	if mimic == null or sim == null:
		return
	var key := TcSpec.key_of(design.get("spec", {}) as Dictionary)
	if key != _mimic_key:
		_mimic_key = key
		_mimic_doc = MimicTcSource.build(design, sim.net)
		mimic.call("set_doc", _mimic_doc)
		_hide_face()
	var pins := {}
	var saved: Dictionary = (proc.get("mimic", {}) as Dictionary).get("pins", {}) as Dictionary
	for k in saved:
		pins[str(k)] = Vector2(float(saved[k][0]), float(saved[k][1]))
	mimic.call("set_pins", pins)


func _refresh_mimic() -> void:
	if mimic == null or not pid_on or sim == null or _mimic_doc.is_empty():
		return
	mimic.call("set_state", MimicTcSource.state(sim, _mimic_doc))
	var signs := {}
	for p in _mimic_doc["pipes"]:
		signs[str(p["id"])] = MimicTcSource.flow_sign(sim, _mimic_doc, p)
	mimic.call("set_flow_signs", signs)
	if _face != null and _face.visible and not _face_el.is_empty():
		var fp := _faceplate_for(_face_el)
		_face.call("set_state", str(fp.get("state", "")), fp.get("state_color", UITheme.C_TEXT))


## A dragged element: its offset is the picture's own layout, saved with the
## design's process (undoable; never restarts the run).
func _on_mimic_moved(id: String, off: Vector2) -> void:
	var p := proc.duplicate(true)
	var pins: Dictionary = ((p.get("mimic", {}) as Dictionary).get("pins", {}) as Dictionary).duplicate(true)
	if off.length() < 0.5:
		pins.erase(id)
	else:
		pins[id] = [snappedf(off.x, 0.1), snappedf(off.y, 0.1)]
	p["mimic"] = {"pins": pins}
	modal.call("set_process_block", p)


## Put every dragged thing back where the assembly has it.
func reset_mimic_layout() -> void:
	var p := proc.duplicate(true)
	p["mimic"] = {"pins": {}}
	modal.call("set_process_block", p)


func _on_mimic_element(e: Dictionary) -> void:
	if int(e.get("cv", -1)) >= 0:
		select_cv(int(e["cv"]))
	var fp := _faceplate_for(e)
	if fp.is_empty():
		_hide_face()
		return
	if _face == null:
		_face = PanelContainer.new()
		_face.set_script(FaceScript)
		_face.name = "ProcessFaceplate"
		modal.add_child(_face)
		_face.connect("dismissed", func() -> void: _face_el = {})
	_face_el = e
	_face.call("show_for", fp, mimic.global_position + (mimic.call("element_rect", e) as Rect2).get_center())


func _hide_face() -> void:
	if _face != null:
		_face.call("dismiss")
	_face_el = {}


## Esc: put an open faceplate away. True when there was one.
func dismiss_faceplate() -> bool:
	if _face != null and _face.visible:
		_hide_face()
		return true
	return false


## The switch behind a picture element: its TcProcControl actuator.
func _act_of(e: Dictionary) -> Dictionary:
	if sim == null:
		return {}
	var want := ""
	match str(e.get("kind", "")):
		"valve": want = "valve:%s" % str(e["part"])
		"pump": want = "pump:%s" % str(e["part"])
		"heater": want = "heater:%s" % str(e["part"])
		"engine": want = "engine:%s" % str(e["part"])
		"end": want = "drain:%s" % str(e.get("ref", ""))
	if want.is_empty():
		return {}
	for a in sim.control_acts:
		if str(a["act"]) == want and str(a["kind"]) == "switch":
			return a
	return {}


## What the faceplate of an element shows ({} = it has none).
func _faceplate_for(e: Dictionary) -> Dictionary:
	var a := _act_of(e)
	if a.is_empty():
		return {}
	var on := TcProcControl.is_on(sim, str(a["act"]))
	var kind := str(e["kind"])
	var words := ["Open", "Closed", "Open it", "Close it"] if kind == "valve" or kind == "end" else ["On", "Off", "Switch on", "Switch off"]
	var key := str(a["key"])
	var lines: Array = []
	if kind == "heater":
		var k := sim.heater_parts.find(str(e["part"]))
		lines.append(["Set to", "%d W" % int(float(TcProcSpec.heater(proc, str(e["part"]))["w"]))])
		if k >= 0 and k < sim.element_t.size():
			lines.append(["Element", "%d °C" % int(round(float(sim.element_t[k]) - 273.15))])
	var buttons: Array = [
		{"id": "on", "text": words[2], "disabled": on, "on_press": func() -> void: _face_cmd(key, "turn_on")},
		{"id": "off", "text": words[3], "disabled": not on, "on_press": func() -> void: _face_cmd(key, "turn_off")}]
	# A control valve's opening / a pump's speed: a number, stepped by tens.
	var num_act := ""
	if kind == "valve":
		num_act = "cvalve:%s" % str(e["part"])
	elif kind == "pump":
		num_act = "pumpspeed:%s" % str(e["part"])
		lines.append(["Moving", "%.1f L/min" % float(sim.pump_lpm.get(str(e["part"]), 0.0))])
	for na in sim.control_acts:
		if num_act != "" and str(na["act"]) == num_act and str(na["kind"]) == "number":
			var cur := TcProcControl.value_of(sim, na)
			var nkey := str(na["key"])
			lines.append(["Opening" if kind == "valve" else "Speed", "%d %%" % int(round(cur))])
			var down := func() -> void: _face_num(nkey, maxf(cur - 10.0, 0.0))
			var upf := func() -> void: _face_num(nkey, minf(cur + 10.0, 100.0))
			if kind == "valve":
				# Its opening IS its state: no separate open / shut.
				buttons = []
				on = cur > 2.0
			buttons.append({"id": "less", "text": "−10 %", "disabled": cur <= 0.0, "on_press": down})
			buttons.append({"id": "more", "text": "+10 %", "disabled": cur >= 100.0, "on_press": upf})
	return {"id": str(e["id"]), "title": str(a["label"]), "subtitle": key,
		"state": words[0] if on else words[1],
		"state_color": MimicSymbols.OPEN if on else MimicSymbols.CLOSED, "lines": lines,
		"buttons": buttons}


func _face_num(key: String, v: float) -> void:
	_manual(key, "set_value", v)
	_refresh_mimic()
	if _face != null and not _face_el.is_empty():
		_face.call("show_for", _faceplate_for(_face_el),
			mimic.global_position + (mimic.call("element_rect", _face_el) as Rect2).get_center())


func _face_cmd(key: String, cmd: String) -> void:
	_manual(key, cmd, 0.0)
	_refresh_mimic()
	if _face != null and not _face_el.is_empty():
		_face.call("show_for", _faceplate_for(_face_el),
			mimic.global_position + (mimic.call("element_rect", _face_el) as Rect2).get_center())


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


func _set_tile(id: String, text: String, sub: String = "") -> void:
	var l: Label = _tile_vals.get(id)
	if l != null and l.text != text:
		l.text = text
	var sl: Label = _tile_subs.get(id)
	if sl != null and sl.text != sub:
		sl.text = sub
		sl.tooltip_text = sub


func _set_now(id: String, text: String, shown: bool = true) -> void:
	var r: KVRow = _now_rows.get(id)
	if r == null:
		return
	if r.visible != shown:
		r.visible = shown
	if shown:
		r.set_value(text)


## Watts the elements are drawing at this moment.
func _heater_w_now() -> float:
	var w := 0.0
	for pid in sim.heater_parts:
		if TcProcControl.is_on(sim, "heater:%s" % pid):
			w += float(sim.heater_w.get(str(pid), 0.0))
	return w


func _refresh_tiles() -> void:
	var r := sim.readings()
	var b := sim.batch_stats()
	var has_bed := bool(b["has_bed"])
	var wood := bool(b["wood"])
	var end_h := float(proc["duration_h"])
	if _batch_head != null:
		_batch_head.set_note("%s of %s" % [_fmt_t(sim.t_s), _fmt_t(end_h * 3600.0)])
	# What the batch has made and used.
	if wood:
		_set_tile("carbon", "%.2f" % float(b["carbon_kg"]), "char is about %d %% carbon" % roundi(TcProcSim.CHAR_C_FRAC * 100.0))
		_set_tile("co2e", "%.2f" % float(b["co2e_kg"]), "the %d %% that lasts 100 years" % roundi(TcProcSim.CHAR_PERM * 100.0))
		var dry := maxf(float(b.get("feed_dry_kg", 0.0)), 1e-9)
		_set_tile("char", "%.2f" % float(b["char_kg"]), "%.0f %% of %.1f kg dry wood" % [float(b["char_kg"]) / dry * 100.0, dry])
	else:
		var why := "no char from this charge" if has_bed else "nothing loaded"
		_set_tile("carbon", "—", why)
		_set_tile("co2e", "—", why)
		_set_tile("char", "—", why)
	var gl := float(b["gas_nl"])
	_set_tile("gas", ("%.0f" % gl) if gl >= 10.0 else ("%.1f" % gl),
		("%.2f MJ of fuel · %.1f MJ/m³" % [float(b["gas_mj"]), float(b["gas_mj"]) / (gl * 0.001)]) if gl > 0.5 else "none yet")
	var hw := _heater_w_now()
	_set_tile("energy", "%.2f" % float(b["heat_kwh"]), ("%s now" % UiText.num(hw, "W")) if hw > 0.0 else "elements off now")
	var has_engine := false
	for u in sim.units:
		has_engine = has_engine or str(u["kind"]) == "engine"
	var ekw := float(r.get("engine_kw", 0.0))
	if has_engine:
		var share := float(b["gen_kwh"]) / maxf(float(b["heat_kwh"]), 1e-9) * 100.0
		_set_tile("gen", "%.2f" % float(b["gen_kwh"]),
			("%.0f W at 48 V now" % (ekw * 1000.0)) if ekw > 0.0 else ("off now · %.0f %% of the heat used" % share))
	else:
		_set_tile("gen", "—", "no generator on this line")
	var liq := float(b["vinegar_kg"]) + float(b["tar_kg"])
	_set_tile("cond", "%.2f" % liq, ("wood vinegar %.2f · tar %.2f" % [float(b["vinegar_kg"]), float(b["tar_kg"])]) if liq > 0.005 else "none yet")
	if has_bed:
		var loaded_kg := float(b["feed_kg"])
		var loaded_l := PI * pow(float(sim.net["cvs"][sim.vessel_cv]["r_in_m"]), 2.0) * sim.bed.height_m * 1000.0
		_set_tile("done", "%.0f" % float(b["done_pct"]), "%.1f of %.1f kg · %.0f of %.0f L" % [float(b["charge_kg"]), loaded_kg,
			loaded_l * float(b["volume_frac"]), loaded_l])
	else:
		_set_tile("done", "—", "nothing loaded")
	# The process at this moment.
	_set_now("bed_max", "%.0f °C" % float(r.get("bed_t_max_c", 0.0)), has_bed)
	_set_now("vessel", "%.0f °C · %+.1f kPa" % [float(r.get("vessel_t_c", 0.0)), float(r.get("vessel_p_kpa_g", 0.0))], r.has("vessel_t_c"))
	var es: Array = []
	for v in r.get("element_t_c", []):
		es.append("%.0f" % float(v))
	_set_now("element", "%s °C" % " / ".join(es), not es.is_empty())
	_set_now("fronts", "%.0f mm / %.0f mm" % [float(r.get("dry_front_mm", 0.0)), float(r.get("pyro_front_mm", 0.0))], has_bed)
	var flow := float(r.get("gas_out_l_min", 0.0))
	var has_out := false
	for bd in sim.net["boundaries"]:
		has_out = has_out or str(bd["role"]) == "product"
	_set_now("gas_flow", ("%.1f L/min · %.1f MJ/m³" % [flow, float(r.get("gas_lhv_mj_nm3", 0.0))]) if float(r.get("gas_out_dry_l_min", 0.0)) > 0.05
		else "%.1f L/min" % flow, has_out)
	_set_now("holder", "%.0f %% full" % float(r.get("holder_pct", 0.0)), r.has("holder_pct"))
	_set_now("genset", ("%.0f W at 48 V" % (ekw * 1000.0)) if ekw > 0.0 else "off", has_engine)
	var co: Array = r.get("coolant_out_c", [])
	var cmax := -INF
	for v2 in co:
		cmax = maxf(cmax, float(v2))
	_set_now("cool", "%.0f °C" % cmax, co.size() > 0)
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
