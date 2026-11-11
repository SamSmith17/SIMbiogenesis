extends Node

## CAMPS & CALCULATOR: one card per festival camp — who lives there, how its
## water / food / firewood arrive and its grey- and blackwater leave (each
## camp's own choice: infinite and metered, its own tanks, or a shared site
## depot), what it has actually taken in and put out (per day, per person,
## in total, and how much of it crossed the camp's boundary), and how closed
## its loops are, with the machines that would close the worst one.
##
## The numbers come from SystemGraphView.festival_camp_rows (CampFlowMeter +
## CampLoopClosure); this window only shows them. Opened from the festival
## panel and from Site Plan's tool row. A ModalFrame; the cards' structure is
## built once per camp set and their numbers refreshed twice a second, so a
## dropdown stays open while the clock runs.

const REFRESH_S := 0.5
## CampTemplates.supply_choices(): the one list of modes and their words.
var SUPPLY: Array = CampTemplates.supply_choices()

var _frame: ModalFrame = null
var _list: VBoxContainer = null
var _totals: Label = null
var _cards: Dictionary = {}   # comp_id -> {table: GridContainer, head: Label, closure: Label, fix: HBoxContainer}
var _sig := "<unbuilt>"
var _accum := 0.0
var _on_look: Callable = Callable()
var _arrival_lbl: Label = null


func open(on_look: Callable = Callable()) -> void:
	_on_look = on_look
	if _frame == null:
		_build()
	_sig = "<unbuilt>"
	_refresh()
	_frame.open()
	set_process(true)


func _ready() -> void:
	set_process(false)


func _build() -> void:
	_frame = ModalFrame.create("Camps & calculator",
		"What each camp takes in and puts out — then close the loops inside the camp",
		Vector2(980, 760), "festival_camps")
	_frame.content_max_w = 1500.0
	add_child(_frame)
	_frame.closed.connect(func() -> void: set_process(false))
	_totals = Label.new()
	_totals.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_totals.add_theme_color_override("font_color", UITheme.C_TEXT)
	_totals.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_frame.body.add_child(_totals)
	var all_row := HBoxContainer.new()
	all_row.add_theme_constant_override("separation", 6)
	_frame.body.add_child(all_row)
	var cap := Label.new()
	cap.text = "Every camp:"
	cap.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	all_row.add_child(cap)
	for m in SUPPLY:
		var b := Button.new()
		b.text = str(m[1])
		UITheme.style_button(b)
		var mode := str(m[0])
		b.pressed.connect(func() -> void:
			var sgv := ServiceLocator.graph()
			if sgv != null:
				sgv.call("set_all_camp_supply", mode)
			_sig = "<unbuilt>"
			_refresh())
		all_row.add_child(b)
	# Living vehicles drive in through the site gate (VehicleDrive): each
	# camp's people arrive with its first vehicle.
	var arr_row := HBoxContainer.new()
	arr_row.add_theme_constant_override("separation", 6)
	_frame.body.add_child(arr_row)
	var cap2 := Label.new()
	cap2.text = "Vehicles:"
	cap2.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	arr_row.add_child(cap2)
	# The three buttons are the timeline's ARRIVE / LEAVE events (the Deploy
	# chip's menu has the same), placed a couple of minutes ahead of now.
	var drive_in := Button.new()
	drive_in.name = "vehicles_drive_in"
	drive_in.text = "Arrive from the gate"
	drive_in.tooltip_text = "Puts an ARRIVE event on the timeline a couple of minutes from now: every living vehicle drives in through the site gate, one every few minutes, and each camp's people are away until it comes (a camp with no vehicle arrives at the event). Drag the flag on the timeline to retime it."
	UITheme.style_button(drive_in)
	drive_in.pressed.connect(func() -> void:
		var sd := _site_deploy()
		if sd != null:
			sd.add_event(SiteDeploySchedule.ACTION_ARRIVE, _now_h() + 2.0 / 60.0)
		_refresh())
	arr_row.add_child(drive_in)
	var here := Button.new()
	here.name = "vehicles_here"
	here.text = "Already here"
	here.tooltip_text = "Remove the Arrive and Leave events: every vehicle stands where it is parked and everyone is here."
	UITheme.style_button(here)
	here.pressed.connect(func() -> void:
		var sd := _site_deploy()
		if sd != null:
			for action in [SiteDeploySchedule.ACTION_ARRIVE, SiteDeploySchedule.ACTION_LEAVE]:
				var ev: Dictionary = sd.event_of(action)
				if not ev.is_empty():
					sd.remove_event(str(ev.get("id", "")))
		var loader := _loader()
		if loader != null:
			loader.call("clear_vehicle_arrivals")
			loader.call("clear_vehicle_departures")
		_refresh())
	arr_row.add_child(here)
	var drive_out := Button.new()
	drive_out.name = "vehicles_drive_out"
	drive_out.text = "Leave through the gate"
	drive_out.tooltip_text = "Puts a LEAVE event on the timeline a couple of minutes from now: every living vehicle drives out through the site gate, the one nearest it last, and each camp is away again once its vehicles are gone. A Pack-up adds one by itself when the crews finish."
	UITheme.style_button(drive_out)
	drive_out.pressed.connect(func() -> void:
		var sd := _site_deploy()
		if sd != null:
			sd.add_event(SiteDeploySchedule.ACTION_LEAVE, _now_h() + 2.0 / 60.0)
		_refresh())
	arr_row.add_child(drive_out)
	var gate_btn := Button.new()
	gate_btn.name = "vehicles_gate_here"
	gate_btn.text = "Set the gate here"
	gate_btn.tooltip_text = "Put the site gate a few metres ahead of the player, facing the way the player looks: the vehicles drive through it that way, into the site."
	UITheme.style_button(gate_btn)
	gate_btn.pressed.connect(func() -> void:
		var loader := _loader()
		var t := get_tree()
		var main := t.current_scene if t != null else null
		var pose := SiteGateBuilder.pose_from_player(main)
		if loader != null and not pose.is_empty() and loader.has_method("set_site_gate_here"):
			loader.call("set_site_gate_here", float(pose["x"]), float(pose["z"]), float(pose["yaw_deg"]))
		_refresh())
	arr_row.add_child(gate_btn)
	# The status line gets its own row and wraps (it used to clip).
	_arrival_lbl = Label.new()
	_arrival_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_arrival_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_arrival_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_frame.body.add_child(_arrival_lbl)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 10)
	_frame.body.add_child(_list)
	_frame.add_button("Copy as CSV", ModalFrame.SECONDARY, _copy_csv,
		"Every camp's metered totals and per-day figures, for a spreadsheet")
	_frame.add_button("Close", ModalFrame.PRIMARY, _frame.close)


func _process(delta: float) -> void:
	_accum += delta
	if _accum < REFRESH_S:
		return
	_accum = 0.0
	_refresh()


func _loader() -> Node:
	var t := get_tree()
	return TerrainSurfaceQuery.find_terrain_loader(t.current_scene) if t != null else null


func _site_deploy() -> SiteDeployDirector:
	var sgv := ServiceLocator.graph()
	if sgv == null or not sgv.has_method("site_deploy"):
		return null
	return sgv.call("site_deploy")


func _now_h() -> float:
	var t := get_tree()
	var main := t.current_scene if t != null else null
	return float(main.call("get_absolute_hours")) if main != null and main.has_method("get_absolute_hours") else 0.0


## "3 vehicles driving in · the last parks at 14:22", "2 vehicles leaving ·
## the last is gone at 18:40", or "already here".
func _arrival_text() -> String:
	var loader := _loader()
	if loader == null or not loader.has_method("vehicle_arrivals"):
		return ""
	var arr: Array = loader.call("vehicle_arrivals")
	var gate_hint := ""
	var g: Dictionary = loader.call("site_gate") if loader.has_method("site_gate") else {}
	if not bool(g.get("placed", true)):
		gate_hint = " No site gate is placed (they use the farthest road end): stand where it should be and press “Set the gate here”."
	var sd := _site_deploy()
	var ev_hint := ""
	if sd != null:
		var ev_a: Dictionary = sd.event_of(SiteDeploySchedule.ACTION_ARRIVE)
		var ev_l: Dictionary = sd.event_of(SiteDeploySchedule.ACTION_LEAVE)
		if not ev_a.is_empty():
			ev_hint += " Arrive at %s." % _hhmm(float(ev_a.get("at_h", 0.0)))
		if not ev_l.is_empty():
			ev_hint += " Leave at %s." % _hhmm(float(ev_l.get("at_h", 0.0)))
		if not ev_a.is_empty() and not bool(sd.people_present_at(_now_h())):
			ev_hint += " Everyone is away until then."
	if arr.is_empty():
		return "Every vehicle is already here." + ev_hint + gate_hint
	var t := get_tree()
	var main := t.current_scene if t != null else null
	var now := float(main.call("get_absolute_hours")) if main != null and main.has_method("get_absolute_hours") else 0.0
	var coming := 0
	var last := -INF
	var leaving := 0
	var gone := 0
	var last_out := -INF
	for a in arr:
		var ad := a as Dictionary
		var ph := float(ad.get("park_h", -INF))
		if ph > now:
			coming += 1
		if ph > -INF:
			last = maxf(last, ph)
		var gh := float(ad.get("gone_h", INF))
		if gh < INF:
			if gh > now:
				leaving += 1
				last_out = maxf(last_out, gh)
			else:
				gone += 1
	if coming > 0:
		return "%s on the way in · the last parks at %s" % [UiText.count(coming, "vehicle"), _hhmm(last)]
	if leaving > 0:
		return "%s leaving · the last is gone at %s" % [UiText.count(leaving, "vehicle"), _hhmm(last_out)]
	if gone > 0:
		return "%s left through the gate." % UiText.count(gone, "vehicle")
	return "%s came in through the gate." % UiText.count(arr.size(), "vehicle")


static func _hhmm(abs_h: float) -> String:
	var hh := fposmod(abs_h, 24.0)
	return "%02d:%02d" % [int(hh), int(fposmod(hh * 60.0, 60.0))]


func _rows() -> Array:
	var sgv := ServiceLocator.graph()
	if sgv == null or not sgv.has_method("festival_camp_rows"):
		return []
	return sgv.call("festival_camp_rows")


func _refresh() -> void:
	if _frame == null:
		return
	if _arrival_lbl != null:
		_arrival_lbl.text = _arrival_text()
	var rows := _rows()
	var sig := ""
	for r in rows:
		var d: Dictionary = r
		sig += "%s|%s;" % [d["id"], d["name"]]
	if sig != _sig:
		_sig = sig
		_rebuild(rows)
	var people := 0
	var water := 0.0
	var food := 0.0
	var grey := 0.0
	var black := 0.0
	for r2 in rows:
		var d2: Dictionary = r2
		people += int(d2["present"])
		for m in (d2["meter"] as Array):
			var md: Dictionary = m
			match str(md["key"]):
				"in:water":
					water += float(md["per_day"])
				"in:food":
					food += float(md["per_day"])
				"out:greywater":
					grey += float(md["per_day"])
				"out:blackwater":
					black += float(md["per_day"])
		_update_card(d2)
	if rows.is_empty():
		_totals.text = "No festival camps yet — Set up the gathering, or paint a camp and give it people."
	else:
		_totals.text = "%s · %s · the whole gathering, per day: %s water in, %s food, %s greywater and %s blackwater out." % [
			UiText.count(rows.size(), "camp"), UiText.count(people, "person", "people"),
			UiText.num(water, "L"), UiText.num(food, "kg"), UiText.num(grey, "L"), UiText.num(black, "L")]


## A camp's vehicles: one chip each (Look flies the view there) and a
## "Getting here" line with the trips and fuel. Rebuilt only when they change.
func _update_vehicle_row(c: Dictionary, veh: Dictionary) -> void:
	var vrow: HFlowContainer = c.get("vrow")
	if vrow == null:
		return
	var sig := "%s|%.0f" % [str(veh.get("ids", [])), float(veh.get("usd", 0.0))]
	if sig == str(c.get("vsig", "")):
		return
	c["vsig"] = sig
	for ch in vrow.get_children():
		vrow.remove_child(ch)
		ch.queue_free()
	var names: Array = veh.get("names", [])
	var pos: Array = veh.get("pos", [])
	if names.is_empty():
		return
	var cap := Label.new()
	cap.text = "Vehicles:"
	cap.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	cap.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	vrow.add_child(cap)
	for i in names.size():
		var b := Button.new()
		b.text = "%s · Look" % str(names[i])
		b.tooltip_text = "Fly the view to this vehicle"
		UITheme.style_button(b)
		var at: Vector2 = pos[i] if i < pos.size() else Vector2.INF
		b.pressed.connect(func() -> void:
			var main := get_tree().current_scene
			_frame.close()
			if main != null and main.has_method("open_settlement_view"):
				main.call("open_settlement_view", at))
		vrow.add_child(b)
	var cost := Label.new()
	cost.text = "Getting here: %s in trips and fuel" % SiteCost.format_usd(float(veh.get("usd", 0.0)))
	cost.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	cost.tooltip_text = "Both legs of each vehicle's trip, plus fuel bought on site"
	vrow.add_child(cost)


func _rebuild(rows: Array) -> void:
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
	_cards.clear()
	for r in rows:
		var d: Dictionary = r
		var card := PanelContainer.new()
		card.add_theme_stylebox_override("panel", UITheme.card_style())
		_list.add_child(card)
		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 4)
		card.add_child(v)
		var head_row := HBoxContainer.new()
		head_row.add_theme_constant_override("separation", 8)
		v.add_child(head_row)
		var head := Label.new()
		head.add_theme_font_size_override("font_size", UITheme.FONT_MD)
		head.add_theme_color_override("font_color", UITheme.C_TEXT)
		head.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		head_row.add_child(head)
		var lot := str(d["lot_id"])
		var opts := {}
		for side in [["inputs", "In"], ["wastes", "Out"]]:
			var cap := Label.new()
			cap.text = str(side[1])
			cap.add_theme_font_size_override("font_size", UITheme.FONT_XS)
			head_row.add_child(cap)
			var opt := OptionButton.new()
			var cur := str((d["supply"] as Dictionary).get(str(side[0]), "infinite"))
			for m in SUPPLY:
				opt.add_item(str(m[1]))
				opt.set_item_metadata(opt.item_count - 1, str(m[0]))
				if str(m[0]) == cur:
					opt.select(opt.item_count - 1)
			var key := str(side[0])
			opts[key] = opt
			opt.item_selected.connect(func(i: int) -> void:
				var sgv := ServiceLocator.graph()
				if sgv != null:
					sgv.call("set_camp_supply", lot, {key: str(opt.get_item_metadata(i))}))
			head_row.add_child(opt)
		var look := Button.new()
		look.text = "Look"
		look.tooltip_text = "Fly the view to this camp"
		UITheme.style_button(look)
		var cid := str(d["id"])
		look.pressed.connect(func() -> void:
			if _on_look.is_valid():
				_frame.close()
				_on_look.call(lot))
		head_row.add_child(look)
		var sub := Button.new()
		sub.text = "Sub-graph"
		sub.tooltip_text = "Open this camp's own systems graph (its habitat, stores and anything you add)"
		UITheme.style_button(sub)
		sub.pressed.connect(func() -> void:
			_frame.close()
			var sgv := ServiceLocator.graph()
			if sgv != null:
				sgv.call("open_camp_subgraph", cid))
		head_row.add_child(sub)
		var table := GridContainer.new()
		table.columns = 5
		table.add_theme_constant_override("h_separation", 18)
		v.add_child(table)
		var closure := Label.new()
		closure.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		closure.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		v.add_child(closure)
		var fix := HBoxContainer.new()
		fix.add_theme_constant_override("separation", 6)
		v.add_child(fix)
		# Its vehicles as chips (each with Look) and what getting here cost.
		var vrow := HFlowContainer.new()
		vrow.add_theme_constant_override("h_separation", 6)
		vrow.add_theme_constant_override("v_separation", 4)
		v.add_child(vrow)
		_cards[cid] = {"table": table, "head": head, "closure": closure, "fix": fix, "fix_sig": "",
			"opts": opts, "vrow": vrow, "vsig": ""}


func _update_card(d: Dictionary) -> void:
	_sync_supply_opts(d)
	var c: Dictionary = _cards.get(str(d["id"]), {})
	if c.is_empty():
		return
	var morale := float(d["morale"])
	(c["head"] as Label).text = "%s · %d of %s%s" % [str(d["name"]), int(d["present"]),
		UiText.count(int(d["headcount"]), "person", "people"),
		(" · morale %d %%" % int(round(morale * 100.0))) if morale >= 0.0 else ""]
	var table: GridContainer = c["table"]
	var meter: Array = d["meter"]
	var want := (meter.size() + 1) * 5
	if table.get_child_count() != want:
		for ch in table.get_children():
			table.remove_child(ch)
			ch.queue_free()
		for h in ["", "per day", "per person / day", "so far", "from / to off site"]:
			table.add_child(_cell(h, UITheme.C_TEXT_S))
		for _m in meter:
			for _k in 5:
				table.add_child(_cell("", UITheme.C_TEXT))
	var i := 5
	for m in meter:
		var md: Dictionary = m
		var u := str(md["unit"])
		(table.get_child(i) as Label).text = str(md["label"])
		(table.get_child(i + 1) as Label).text = UiText.num(float(md["per_day"]), u)
		(table.get_child(i + 2) as Label).text = UiText.num(float(md["per_person_day"]), u)
		(table.get_child(i + 3) as Label).text = UiText.num(float(md["total"]), u)
		(table.get_child(i + 4) as Label).text = UiText.num(float(md.get("offsite_total", 0.0)), u) \
			if md.has("offsite_total") else "—"
		i += 5
	var cl: Dictionary = d["closure"]
	var parts := PackedStringArray()
	for k in (cl.get("kinds", {}) as Dictionary).keys():
		parts.append("%s %d %%" % [str(CampLoopClosure.LABELS.get(str(k), str(k))),
			int(round(float(cl["kinds"][k]) * 100.0))])
	(c["closure"] as Label).text = "Loops closed: %d %%   (%s)" % [int(round(float(cl.get("score", 0.0)) * 100.0)),
		", ".join(parts)] if not parts.is_empty() else "Loops closed: —"
	_update_vehicle_row(c, d.get("vehicles", {}))
	# The fixes for the worst loop, rebuilt only when it changes.
	var sgv := ServiceLocator.graph()
	var model: Variant = sgv.get("model") if sgv != null else null
	var sugg: Array = CampLoopClosure.suggest(model, str(d["id"]), cl) if model != null else []
	var fsig := str(sugg.size()) + ("" if sugg.is_empty() else str((sugg[0] as Dictionary)["kind"]))
	if fsig == str(c["fix_sig"]):
		return
	c["fix_sig"] = fsig
	var fix: HBoxContainer = c["fix"]
	for ch2 in fix.get_children():
		fix.remove_child(ch2)
		ch2.queue_free()
	if sugg.is_empty():
		return
	var s0: Dictionary = sugg[0]
	var lbl := _cell(str(s0["text"]) + ":", UITheme.C_WARN)
	fix.add_child(lbl)
	if (s0["presets"] as Array).is_empty():
		fix.add_child(_cell("nothing in the library makes this yet", UITheme.C_TEXT_S))
	for p in (s0["presets"] as Array):
		var b := Button.new()
		b.text = "+ " + str(p)
		b.tooltip_text = "Add a %s inside this camp, wired to its own tanks" % str(p)
		UITheme.style_button(b)
		var cid := str(d["id"])
		var label := str(p)
		b.pressed.connect(func() -> void:
			var sgv2 := ServiceLocator.graph()
			var m2: Variant = sgv2.get("model") if sgv2 != null else null
			if m2 != null and not CampLoopClosure.apply(m2, cid, label).is_empty():
				c["fix_sig"] = ""
				_refresh())
		fix.add_child(b)


func _cell(t: String, col: Color) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	l.add_theme_color_override("font_color", col)
	return l


func _copy_csv() -> void:
	var lines := PackedStringArray(["camp,people,item,unit,per_day,per_person_day,total,offsite_total"])
	for r in _rows():
		var d: Dictionary = r
		for m in (d["meter"] as Array):
			var md: Dictionary = m
			lines.append("\"%s\",%d,\"%s\",%s,%.3f,%.3f,%.3f,%.3f" % [str(d["name"]), int(d["headcount"]),
				str(md["label"]).strip_edges(), str(md["unit"]), float(md["per_day"]),
				float(md["per_person_day"]), float(md["total"]), float(md.get("offsite_total", 0.0))])
	DisplayServer.clipboard_set("\n".join(lines))


## A camp's supply set elsewhere (Every camp, the site editor) shows in its
## dropdowns without rebuilding the card.
func _sync_supply_opts(d: Dictionary) -> void:
	var c: Dictionary = _cards.get(str(d.get("id", "")), {})
	var opts: Dictionary = c.get("opts", {})
	for key in opts.keys():
		var opt: OptionButton = opts[key]
		if not is_instance_valid(opt):
			continue
		var cur := str((d.get("supply", {}) as Dictionary).get(str(key), "infinite"))
		for i in opt.item_count:
			if str(opt.get_item_metadata(i)) == cur and opt.selected != i:
				opt.select(i)
