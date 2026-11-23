extends PanelContainer

## The editor for one terraced field (TerraceRuntime): a dock on the right
## edge while the T toolbar's Terrace tool has a field selected. Every row
## writes the field's record through the runtime (one undo step per change;
## a slider being dragged adds to the same step), and a live block underneath
## reads the field's graph node: the water held, what the intake takes, what
## spills out, the crop and the water in each step, top to bottom.

const WIDTH := 360.0
const LIVE_S := 0.5
const APPLY_S := 0.3

signal closed

var runtime: TerraceRuntime = null
var field_id := ""

var _head: Dictionary = {}
var _rows: Dictionary = {}           ## key -> FormRow
var _wire_rows: Dictionary = {}      ## port -> FormRow
var _live_lbl: Label = null
var _steps_box: VBoxContainer = null
var _delete_btn: Button = null
var _delete_armed := false
var _live := 0.0
var _pending: Dictionary = {}
var _apply_timer: Timer = null
var _merge := false
var _last_flush_ms := 0
var _syncing := false
var _work_lbl: Label = null
var _step_sel := -999999
var _step_edit: VBoxContainer = null
var _step_title: Label = null
var _step_crop: OptionButton = null
var _step_flood: CheckBox = null


func _ready() -> void:
	name = "TerraceEditorDock"
	set_meta("ui_dock", true)
	add_theme_stylebox_override("panel", UITheme.panel_style())
	anchor_left = 1.0
	anchor_right = 1.0
	anchor_top = 0.0
	anchor_bottom = 1.0
	offset_left = -WIDTH - 10.0
	offset_right = -10.0
	offset_top = 64.0
	offset_bottom = -200.0
	mouse_filter = Control.MOUSE_FILTER_STOP
	_apply_timer = Timer.new()
	_apply_timer.one_shot = true
	_apply_timer.wait_time = APPLY_S
	_apply_timer.timeout.connect(_flush_pending)
	add_child(_apply_timer)
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", UITheme.SPACE_SM)
	add_child(outer)
	_head = DockShell.header("Terraces", "", Callable(self, "_on_close"))
	outer.add_child(_head["row"])
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(scroll)
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 4)
	scroll.add_child(body)
	_build(body)
	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", UITheme.SPACE_SM)
	outer.add_child(foot)
	var graph_btn := _button("Open in graph", "Show this field's node in the systems graph", _open_in_graph)
	foot.add_child(graph_btn)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(sp)
	_delete_btn = _button("Delete", "Delete these terraces (the hillside comes back)", _on_delete)
	_delete_btn.name = "terrace_delete"
	foot.add_child(_delete_btn)


func _button(text: String, tip: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(b)
	b.pressed.connect(cb)
	return b


func _build(body: VBoxContainer) -> void:
	var name_row := FormRow.text_edit("Name", "Terraces", Callable(), "", "terrace_name")
	(name_row.control as LineEdit).text_submitted.connect(func(t: String) -> void:
		(name_row.control as LineEdit).release_focus()
		if not t.strip_edges().is_empty():
			runtime.update(field_id, {"name": t.strip_edges()}))
	body.add_child(name_row)
	_rows["name"] = name_row
	body.add_child(SectionHeader.make("Steps", "mountain"))
	_slider(body, "step_h", "Step height", 0.3, 5.0, 0.1, "m",
		"How much each step rises over the one below. Taller steps are narrower on the same slope.")
	_slider(body, "riser_run", "Riser 1:", 0.2, 3.0, 0.05, "",
		"How far the wall between steps runs across for each metre it rises (0.6 = steep, 2 = a gentle bank).")
	_slider(body, "feather_m", "Edge blend", 0.0, 20.0, 0.5, "m",
		"How far in from the outline the steps fade back into the natural hillside.")
	body.add_child(SectionHeader.make("Water", "droplet"))
	var fl := FormRow.check("Flooded", "Hold standing water", func(on: bool) -> void:
		_queue({"flooded": on}), "Paddies hold water behind low bunds; dry steps only hold what the soil does.",
		"terrace_flooded")
	body.add_child(fl)
	_rows["flooded"] = fl
	_slider(body, "bund_h_cm", "Water depth", 3.0, 40.0, 1.0, "cm",
		"How deep the water stands before it spills over the bund to the step below.")
	var modes: Array = []
	for m in TerraceField.INFLOW_MODES:
		modes.append([m, str(TerraceField.INFLOW_LABELS[m])])
	var mo := FormRow.option("Intake", modes, func(m: Variant) -> void:
		runtime.update(field_id, {"inflow_mode": str(m)}),
		"Keep it full takes only what tops the paddies up; Pump steadily takes the rate below and the extra cascades out of the bottom.",
		"terrace_intake")
	body.add_child(mo)
	_rows["inflow_mode"] = mo
	_slider(body, "inflow_lph", "Intake rate", 0.0, 50000.0, 100.0, "L/h",
		"The most the intake (a pump on the water store) puts into the top step.")
	_slider(body, "perc_mm_d", "Seepage", 0.0, 15.0, 0.5, "mm/day",
		"Water lost down through a flooded floor. A well-puddled paddy loses 1–5 mm a day.")
	_wire_row(body, "water_in", "Water from", "nothing (rain only)",
		"The store the intake pumps from (the top step's water).")
	_wire_row(body, "water_out", "Overflow to", "runs off the hill",
		"Where the water spilling off the lowest steps goes.")
	var fill_row := HBoxContainer.new()
	fill_row.add_theme_constant_override("separation", UITheme.SPACE_SM)
	var fill_b := _button("Fill now", "Fill every step to its bund at once (to see it cascade)", func() -> void:
		runtime.set_fill(field_id, 1.0))
	fill_b.name = "terrace_fill"
	fill_row.add_child(fill_b)
	var drain_b := _button("Drain", "Empty every step at once", func() -> void: runtime.set_fill(field_id, 0.0))
	drain_b.name = "terrace_drain"
	fill_row.add_child(drain_b)
	body.add_child(fill_row)
	body.add_child(SectionHeader.make("Crop", "sprout"))
	var crops: Array = []
	for c in TerraceField.CROP_ORDER:
		var info := TerraceField.crop_info(str(c))
		crops.append([c, "%s%s" % [str(info["label"]), "  (wet)" if bool(info["wet"]) else ""]])
	var co := FormRow.option("Grows", crops, func(c: Variant) -> void:
		runtime.update(field_id, {"crop": str(c), "plant_abs_h": runtime.call("_now_h")}),
		"What the steps grow. Rice, reeds and taro want standing water.", "terrace_crop")
	body.add_child(co)
	_rows["crop"] = co
	var sow := _button("Sow again now", "Start a new crop from today", func() -> void: runtime.sow_now(field_id))
	body.add_child(sow)
	_wire_row(body, "harvest_out", "Harvest to", "nowhere yet",
		"The store the harvest goes into at the end of each crop.")
	_wire_row(body, "residue_out", "Straw to", "left on the field",
		"Stalks and leaves of a food crop (compost, mulch, the digester).")
	_wire_row(body, "fuel_in", "Diesel from", "bought in",
		"The diesel store the skid steer or tractor fills up from. Wired, the machines stop when it runs dry.")
	body.add_child(SectionHeader.make("Work", "hammer"))
	var labs: Array = []
	for m in TerraceField.LABOUR_MODES:
		labs.append([m, str(TerraceField.LABOUR_LABELS[m])])
	var lo := FormRow.option("Farmed by", labs, func(m: Variant) -> void:
		runtime.update(field_id, {"labour": str(m)}),
		"Who prepares, plants, weeds and harvests each step. By hand, the camp's people come out in crews and work down each paddy in a line; small machines need an operator and fuel.",
		"terrace_labour")
	body.add_child(lo)
	_rows["labour"] = lo
	var bms: Array = []
	for m in TerraceField.BUILD_MODES:
		bms.append([m, str(TerraceField.BUILD_LABELS[m])])
	var bo := FormRow.option("Cut by", bms, func(m: Variant) -> void:
		runtime.set_build_mode(field_id, str(m)),
		"How the steps are cut into the hill. By hand, a crew digs them one at a time from the top down; a mini excavator is quicker and burns diesel. A field already cut stays cut.",
		"terrace_build_mode")
	body.add_child(bo)
	_rows["build_mode"] = bo
	var dig_now := _button("Finish digging now", "Cut every step at once (no crew, no cost)", func() -> void:
		runtime.finish_dig_now(field_id))
	dig_now.name = "terrace_dig_now"
	body.add_child(dig_now)
	_rows["dig_now"] = dig_now
	_work_lbl = Label.new()
	_work_lbl.name = "terrace_work"
	_work_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_work_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_work_lbl.add_theme_color_override("font_color", UITheme.C_TEXT)
	body.add_child(_work_lbl)
	body.add_child(SectionHeader.make("Now", "gauge"))
	_live_lbl = Label.new()
	_live_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_live_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_live_lbl.add_theme_color_override("font_color", UITheme.C_TEXT)
	body.add_child(_live_lbl)
	_steps_box = VBoxContainer.new()
	_steps_box.add_theme_constant_override("separation", 1)
	body.add_child(_steps_box)
	# One step's own crop and water (click a step above).
	_step_edit = VBoxContainer.new()
	_step_edit.visible = false
	_step_edit.add_theme_constant_override("separation", 2)
	body.add_child(_step_edit)
	_step_title = Label.new()
	_step_title.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_step_title.add_theme_color_override("font_color", UITheme.C_AMBER)
	_step_edit.add_child(_step_title)
	var srow := HBoxContainer.new()
	srow.add_theme_constant_override("separation", UITheme.SPACE_SM)
	_step_edit.add_child(srow)
	_step_crop = OptionButton.new()
	_step_crop.name = "terrace_step_crop"
	_step_crop.focus_mode = Control.FOCUS_NONE
	_step_crop.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_step_crop.tooltip_text = "What this step grows"
	for c in TerraceField.CROP_ORDER:
		_step_crop.add_item(TerraceField.crop_label(str(c)))
		_step_crop.set_item_metadata(_step_crop.item_count - 1, str(c))
	_step_crop.item_selected.connect(func(i: int) -> void:
		if not _syncing:
			var crop := str(_step_crop.get_item_metadata(i))
			runtime.set_step(field_id, _step_sel, {"crop": crop,
				"flooded": bool(TerraceField.crop_info(crop)["wet"])}))
	srow.add_child(_step_crop)
	_step_flood = CheckBox.new()
	_step_flood.name = "terrace_step_flooded"
	_step_flood.text = "Flooded"
	_step_flood.focus_mode = Control.FOCUS_NONE
	_step_flood.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_step_flood.toggled.connect(func(on: bool) -> void:
		if not _syncing:
			runtime.set_step(field_id, _step_sel, {"flooded": on}))
	srow.add_child(_step_flood)
	var same := _button("Like the field", "This step grows what the field grows", func() -> void:
		runtime.set_step(field_id, _step_sel, {}))
	same.name = "terrace_step_reset"
	srow.add_child(same)


func _slider(body: VBoxContainer, key: String, label: String, lo: float, hi: float, step: float,
		unit: String, tip: String) -> void:
	var r := FormRow.slider(label, lo, hi, lo, step, unit, func(v: float) -> void:
		if key == "bund_h_cm":
			_queue({"bund_h": v / 100.0})
		else:
			_queue({key: v}), tip, "terrace_" + key)
	body.add_child(r)
	_rows[key] = r


func _wire_row(body: VBoxContainer, port: String, label: String, none_text: String, tip: String) -> void:
	var o := OptionButton.new()
	o.focus_mode = Control.FOCUS_NONE
	var r := FormRow.make(label, o, tip, "", "terrace_wire_" + port)
	o.item_selected.connect(func(idx: int) -> void:
		if _syncing:
			return
		var view := ServiceLocator.graph()
		if view != null:
			view.call("terrace_wire", field_id, port, str(o.get_item_metadata(idx)))
			_refresh_wires())
	o.set_meta("none_text", none_text)
	body.add_child(r)
	_wire_rows[port] = r


## Changes from a slider wait a moment and land as one step.
func _queue(patch: Dictionary) -> void:
	if _syncing or runtime == null:
		return
	for k in patch.keys():
		_pending[k] = patch[k]
	_apply_timer.start()


func _flush_pending() -> void:
	if _pending.is_empty() or runtime == null:
		return
	# A slider being dragged keeps adding to one undo step; a pause ends it.
	var now := Time.get_ticks_msec()
	runtime.update(field_id, _pending, _merge and now - _last_flush_ms < 1500)
	_merge = true
	_last_flush_ms = now
	_pending.clear()


func open_field(rt: TerraceRuntime, id: String) -> void:
	runtime = rt
	field_id = id
	_merge = false
	_pending.clear()
	_step_sel = TerraceField.NO_STEP
	_disarm_delete()
	visible = true
	HudLayout.claim_right_dock("terrace_dock", self, WIDTH)
	sync_from_record()
	_refresh_live()


func close_dock() -> void:
	_flush_pending()
	visible = false
	field_id = ""
	HudLayout.release("terrace_dock")


func _on_close() -> void:
	close_dock()
	closed.emit()


func sync_from_record() -> void:
	if runtime == null:
		return
	var r := TerraceField.resolve(runtime.record(field_id))
	if r.is_empty():
		return
	_syncing = true
	DockShell.set_subtitle(_head, _subtitle())
	(_head["title"] as Label).text = str(r["name"])
	(_rows["name"].control as LineEdit).text = str(r["name"])
	for k in ["step_h", "riser_run", "feather_m", "inflow_lph", "perc_mm_d"]:
		(_rows[k] as FormRow).set_value(float(r[k]))
	(_rows["bund_h_cm"] as FormRow).set_value(float(r["bund_h"]) * 100.0)
	(_rows["flooded"] as FormRow).set_value(bool(r["flooded"]))
	(_rows["inflow_mode"] as FormRow).set_value(str(r["inflow_mode"]))
	(_rows["crop"] as FormRow).set_value(str(r["crop"]))
	(_rows["bund_h_cm"] as FormRow).set_enabled(bool(r["flooded"]))
	(_rows["perc_mm_d"] as FormRow).set_enabled(bool(r["flooded"]))
	(_rows["labour"] as FormRow).set_value(str(r["labour"]))
	(_rows["build_mode"] as FormRow).set_value(str(r["build_mode"]))
	_sync_step_edit()
	_syncing = false
	_refresh_wires()


func _sync_step_edit() -> void:
	if _step_edit == null:
		return
	var r := runtime.record(field_id)
	_step_edit.visible = _step_sel != TerraceField.NO_STEP and not r.is_empty()
	if not _step_edit.visible:
		return
	var was := _syncing
	_syncing = true
	var ss := TerraceField.step_setting(r, _step_sel)
	var own := (TerraceField.resolve(r)["steps"] as Dictionary).has(str(_step_sel))
	_step_title.text = I18n.f("Step {step_sel} · {own}", {"step_sel": "%d" % _step_num(_step_sel), "own": "its own crop" if own else "as the field"})
	for i in _step_crop.item_count:
		if str(_step_crop.get_item_metadata(i)) == str(ss["crop"]):
			_step_crop.select(i)
	_step_flood.button_pressed = bool(ss["flooded"])
	_syncing = was


## Steps are numbered from the bottom (1) up.
func _step_num(m: int) -> int:
	var ms := {}
	for p in runtime.paddies(field_id):
		ms[int((p as Dictionary)["m"])] = true
	var keys: Array = ms.keys()
	keys.sort()
	return keys.find(m) + 1


func _subtitle() -> String:
	var inf := runtime.info(field_id)
	var r: Dictionary = inf.get("rec", {})
	var st: Dictionary = inf.get("stats", {})
	if st.is_empty():
		return "cutting the steps…"
	return "%s · %s · %s of fields" % [TerraceField.crop_label(str(r.get("crop", ""))),
		UiText.count(int(st.get("steps", 0)), "step"),
		UiText.num(float(st.get("floor_m2", 0.0)), "m²", 3)]


func _refresh_wires() -> void:
	var view := ServiceLocator.graph()
	_syncing = true
	for port in _wire_rows.keys():
		var r: FormRow = _wire_rows[port]
		var o := r.control as OptionButton
		o.clear()
		o.add_item(str(o.get_meta("none_text")))
		o.set_item_metadata(0, "")
		var sel := 0
		if view != null and view.has_method("terrace_store_choices"):
			var choices: Array = view.call("terrace_store_choices", field_id, str(port))
			for c in choices:
				var cd: Dictionary = c
				var dist := float(cd["dist_m"])
				var txt := str(cd["name"])
				if dist >= 0.0:
					txt += "  · %d m" % int(roundf(dist))
				o.add_item(txt)
				o.set_item_metadata(o.item_count - 1, str(cd["id"]))
				if bool(cd["wired"]):
					sel = o.item_count - 1
		o.select(sel)
		var rec2 := runtime.record(field_id)
		if port == "fuel_in":
			r.visible = TerraceField.wants_fuel(TerraceField.resolve(rec2))
		else:
			r.visible = port != "residue_out" or float(TerraceField.crop_info(
				str(rec2.get("crop", "fallow")))["food"]) > 0.0
	_syncing = false


func _process(delta: float) -> void:
	if not visible or runtime == null or field_id.is_empty():
		return
	_live -= delta
	if _live > 0.0:
		return
	_live = LIVE_S
	if runtime.record(field_id).is_empty():
		_on_close()
		return
	_refresh_live()


func _refresh_live() -> void:
	var inf := runtime.info(field_id)
	if inf.is_empty():
		return
	DockShell.set_subtitle(_head, _subtitle())
	var n: Dictionary = inf.get("node", {})
	var st: Dictionary = inf.get("stats", {})
	var lines := PackedStringArray()
	if n.is_empty():
		lines.append("Not on the graph yet.")
	else:
		var held := float(n.get("water_held_l", 0.0))
		var cap := float(st.get("cap_l", 0.0))
		lines.append("Water held: %s of %s" % [UiText.num(held, "L", 3), UiText.num(cap, "L", 3)])
		lines.append("Intake: %s/h · spilling out: %s/h" % [UiText.num(float(n.get("inflow_lph_live", 0.0)), "L", 3),
			UiText.num(float(n.get("outflow_lph", 0.0)), "L", 3)])
		var pct := float(n.get("crop_pct", -1.0))
		if pct >= 0.0:
			lines.append("Crop %d%% through its cycle · watered %d%%" % [int(pct),
				int(roundf(float(n.get("water_factor", 0.0)) * 100.0))])
			lines.append("Standing: %s · last harvest: %s" % [UiText.num(float(n.get("standing_kg", 0.0)), "kg", 3),
				UiText.num(float(n.get("last_harvest_kg", 0.0)), "kg", 3)])
		else:
			lines.append("Nothing growing.")
		lines.append(str(n.get("display_value", "")))
	_live_lbl.text = "\n".join(lines)
	_refresh_work(inf)
	_refresh_steps()


## The work: what the crews are doing, what it has cost so far, and what a
## season and the digging take by hand and by machine.
func _refresh_work(inf: Dictionary) -> void:
	var n: Dictionary = inf.get("node", {})
	var w: Dictionary = inf.get("work", {})
	var dig: Dictionary = inf.get("dig", {})
	var season: Dictionary = inf.get("season", {})
	var r: Dictionary = inf.get("rec", {})
	var lines := PackedStringArray()
	var ds := str(w.get("dig", ""))
	if not ds.is_empty():
		lines.append(ds)
	var cs := str(w.get("crew", ""))
	if not cs.is_empty():
		lines.append("Farm crew: " + cs)
	var ms := str(w.get("machine", ""))
	if not ms.is_empty():
		lines.append("Tractor: " + ms)
	var led: Dictionary = n.get("farm_ledger", {})
	if not led.is_empty():
		var t := "Worked so far: %s (%s of work, %s of food)" % [UiText.num(float(led.get("labour_h", 0.0)), "h", 3),
			UiText.num(float(led.get("work_kwh", 0.0)) * 1000.0, "Wh", 3),
			UiText.num(float(led.get("food_kwh", 0.0)) * 1000.0, "Wh", 3)]
		if float(led.get("fuel_l", 0.0)) > 0.0:
			t += " · %s diesel" % UiText.num(float(led["fuel_l"]), "L", 3)
		lines.append(t)
		var got := float(led.get("food_kg", 0.0)) + float(led.get("biomass_kg", 0.0))
		if got > 0.0 or int(led.get("missed", 0)) > 0:
			lines.append("Brought in %s · %s missed · %s lost waiting" % [UiText.num(got, "kg", 3),
				UiText.count(int(led.get("missed", 0)), "weeding"),
				UiText.num(float(led.get("lost_kg", 0.0)), "kg", 2)])
	if not season.is_empty():
		lines.append("A season here: %s by hand (%s of work, %s of food); with machines %s and %s of diesel (%s)" % [
			UiText.num(float(season["hand_h"]), "h", 3),
			UiText.num(float(season["work_kwh"]) * 1000.0, "Wh", 3),
			UiText.num(float(season["food_kwh"]) * 1000.0, "Wh", 3),
			UiText.num(float(season["machine_op_h"]), "h", 3),
			UiText.num(float(season["fuel_l"]), "L", 3),
			UiText.num(float(season["fuel_kwh"]) * 1000.0, "Wh", 3)])
		if float(season.get("establish_h", 0.0)) > 0.0:
			lines.append("Planting it the first time: %s more" % UiText.num(float(season["establish_h"]), "h", 3))
	if not dig.is_empty() and float(dig.get("vol_m3", 0.0)) > 0.0:
		var hd: Dictionary = dig["hand"]
		var sd: Dictionary = dig["skid_steer"]
		var td: Dictionary = dig["tractor"]
		lines.append("Cutting it: %s of earth — %s by hand (%s of work, %s of food); skid steer %s and %s of diesel; tractor %s and %s" % [
			UiText.num(float(dig["vol_m3"]), "m³", 3), UiText.num(float(hd["hours"]), "h", 3),
			UiText.num(float(hd["work_kwh"]) * 1000.0, "Wh", 3), UiText.num(float(hd["food_kwh"]) * 1000.0, "Wh", 3),
			UiText.num(float(sd["machine_h"]), "h", 3), UiText.num(float(sd["fuel_l"]), "L", 3),
			UiText.num(float(td["machine_h"]), "h", 3), UiText.num(float(td["fuel_l"]), "L", 3)])
		var dl: Dictionary = dig.get("ledger", {})
		if float(dl.get("fuel_l", 0.0)) > 0.0:
			lines.append("Digging so far: %s of machine, %s of diesel (%s bought in)" % [
				UiText.num(float(dl.get("machine_h", 0.0)), "h", 3), UiText.num(float(dl["fuel_l"]), "L", 3),
				UiText.num(float(dl.get("fuel_bought_l", 0.0)), "L", 3)])
	_work_lbl.text = "\n".join(lines)
	var fuel_row: FormRow = _wire_rows.get("fuel_in")
	if fuel_row != null and fuel_row.visible != TerraceField.wants_fuel(r):
		_refresh_wires()
	(_rows["dig_now"] as Button).visible = str(r.get("build_mode", "instant")) != "instant" \
		and float(dig.get("done_share", 1.0)) < 0.999


## One bar per step, top to bottom: how full, and whether it spills.
func _refresh_steps() -> void:
	var pads := runtime.paddies(field_id)
	while _steps_box.get_child_count() > mini(pads.size(), 40):
		var c := _steps_box.get_child(_steps_box.get_child_count() - 1)
		_steps_box.remove_child(c)
		c.queue_free()
	for i in mini(pads.size(), 40):
		var p: Dictionary = pads[i]
		var row: HBoxContainer
		if i < _steps_box.get_child_count():
			row = _steps_box.get_child(i) as HBoxContainer
		else:
			row = HBoxContainer.new()
			row.add_theme_constant_override("separation", 4)
			row.mouse_filter = Control.MOUSE_FILTER_STOP
			row.gui_input.connect(func(ev: InputEvent) -> void:
				if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed \
						and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
					_step_sel = int(row.get_meta("m", TerraceField.NO_STEP))
					_sync_step_edit())
			var lb := Label.new()
			lb.mouse_filter = Control.MOUSE_FILTER_PASS
			lb.custom_minimum_size = Vector2(118, 0)
			lb.add_theme_font_size_override("font_size", UITheme.FONT_XS)
			lb.add_theme_color_override("font_color", UITheme.C_TEXT_S)
			row.add_child(lb)
			var bar := ProgressBar.new()
			bar.show_percentage = false
			bar.custom_minimum_size = Vector2(120, 10)
			bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			bar.max_value = 1.0
			UITheme.style_progress(bar, UITheme.C_INFO)
			row.add_child(bar)
			var sp := Label.new()
			sp.custom_minimum_size = Vector2(54, 0)
			sp.add_theme_font_size_override("font_size", UITheme.FONT_XS)
			sp.add_theme_color_override("font_color", UITheme.C_INFO)
			row.add_child(sp)
			_steps_box.add_child(row)
		(row.get_child(0) as Label).text = "Step %d · %s" % [_step_num(int(p["m"])),
			UiText.num(float(p["area"]), "m²", 2)]
		(row.get_child(0) as Label).tooltip_text = str(p.get("stage", ""))
		row.set_meta("m", int(p["m"]))
		(row.get_child(1) as ProgressBar).value = float(p["fill"])
		var spill := float(p["spill_lph"])
		(row.get_child(2) as Label).text = ("↓ %s/h" % UiText.num(spill, "L", 2)) if spill > 1.0 else ""


func _open_in_graph() -> void:
	var view := ServiceLocator.graph()
	if view == null:
		return
	var gid := str(view.call("terrace_node_id", field_id))
	if gid.is_empty():
		return
	var main := get_tree().current_scene
	if main != null and main.has_method("open_node_in_graph"):
		main.call("open_node_in_graph", gid)
	elif view.has_method("open_node_in_graph"):
		view.call("open_node_in_graph", gid)


func _on_delete() -> void:
	if not _delete_armed:
		_delete_armed = true
		_delete_btn.text = "Really delete?"
		return
	var id := field_id
	_disarm_delete()
	close_dock()
	runtime.delete(id)
	closed.emit()


func _disarm_delete() -> void:
	_delete_armed = false
	if _delete_btn != null:
		_delete_btn.text = "Delete"
