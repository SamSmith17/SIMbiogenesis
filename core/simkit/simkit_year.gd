extends RefCounted

## Whole-system design harness, part 2: run the LIVE graph of a loaded world
## for days or years on the game's own simulation, and account for it.
##
## It is the same order as SimBakeStepper (energy -> people -> resources ->
## the next step's DC), with three things the bake does not do:
##   - the graph's automations run in sim time (AutomationSim);
##   - the step is short (default 6 min, the population's own substep), because
##     the flow engine's draws are all-or-nothing per step;
##   - the view's machine ticks (HomeBiogas, tools, extruder, sheet press) run
##     on the cursor.
## Every piece is the game's: SolarUI's pure solar evaluator (Meeus SPA +
## the site's weather archive), EnergyTimeline.step_soc with SolarUI's
## efficiencies, floor and AC hysteresis, GraphAcLoad for the load,
## NpcPopulationBridge.tick_at for the people and their chores,
## ResourceFlowEngine.render_step for everything else.
##
## The caller owns the world: this claims the clock (time_scale 0), suspends
## the ambient tick, and hands both back in `release()`.

const CLOCK_OWNER := "sysdesign_year"
const DcWiring := preload("res://system_graph/dc_power_wiring.gd")

var main: Node
var sgv: Node
var solar: Node
var model: GraphModel
var flow: Object
var bridge: Object
var automations: AutomationSim
## The design's control logic (opts.logic: blocks already on graph ids).
var logic: ScadaLogicRun
## The design's alarm rules (opts.alarms), judged with nobody to acknowledge.
var alarms: ScadaAlarmRun

var step_h := 0.1
var start_abs := 0.0
var end_abs := 0.0
var cursor := 0.0

# Battery (SolarUI's own numbers, read at begin()).
var cap_kwh := 16.0
var soc := 8.0
var ceff := 0.95
var deff := 0.95
var floor_kwh := 1.6
var shutdown_kwh := 1.6
var resume_kwh := 3.2
var ac_on := true
var dc_kw := 0.0

# Accounting.
var acc := {}             # item id -> dict
var energy := {"solar_kwh": 0.0, "raw_kwh": 0.0, "load_kwh": 0.0, "aux_kwh": 0.0,
	"ac_off_h": 0.0, "min_soc_pct": 100.0, "curtailed_kwh": 0.0, "ac_off_events": 0}
var people := {"min_present": 9999, "min_morale": 1.0, "morale_sum": 0.0, "samples": 0,
	"departures": 0, "starved_h": {}, "blocked_h": {}, "ideal_import": {}, "ideal_export": {}}
var daily: Array = []     # one row per sim day
var events: Array = []    # notable things, capped
var auto_log_n := 0
var steps := 0
var t_pop_us := 0
var t_flow_us := 0
var t_misc_us := 0
var _feeds := {}
var _last_day := -1
var _day_acc := {}
var _year_loaded := 0
var _machine_tick_every := 5
var _released := false
var _pop_driven := false
var _conn_flow: Dictionary = {}
var _conn_ends := {}
## Per wire over the whole run: conn id -> [kind, total qty] (the engine's
## per-wire flows × dt). The report's "flows" block and its loop metrics.
var conn_tot := {}
var _live_engine: Node = null
var _live_engine_was := false


func begin(p_main: Node, p_sgv: Node, opts: Dictionary) -> String:
	main = p_main
	sgv = p_sgv
	model = sgv.get("model")
	flow = sgv.call("resource_flow_engine")
	bridge = sgv.call("npc_population_bridge")
	solar = main.get_node_or_null("UILayer/SolarUI")
	if solar == null:
		solar = main.find_child("SolarUI", true, false)
	if model == null or flow == null or solar == null:
		return "no graph / flow engine / SolarUI"
	step_h = float(opts.get("step_min", 6.0)) / 60.0
	start_abs = float(opts.get("start_abs", float(main.call("get_absolute_hours"))))
	end_abs = start_abs + float(opts.get("days", 365.0)) * 24.0
	cursor = start_abs

	main.call("push_clock_claim", CLOCK_OWNER, {"time_scale": 0.0}, true)
	# The live AutomationEngine evaluates the same rules against the LIVE
	# battery and sensors at 10 Hz. Left running it fights the sim-time rules
	# (a "battery nearly flat" rule read SolarUI's live battery and switched
	# machines off the sim had just switched on). Fork edit stops it the same way.
	_live_engine = main.get_node_or_null("/root/AutomationEngine")
	if _live_engine != null:
		_live_engine_was = _live_engine.is_processing()
		_live_engine.set_process(false)
	main.call("set_absolute_hours", start_abs)
	sgv.call("set_ambient_flow_suspended", true)
	if sgv.has_method("_sync_solar_ui_from_graph"):
		sgv.call("_sync_solar_ui_from_graph")

	cap_kwh = maxf(float(solar.get("BATTERY_CAPACITY_KWH")), 0.001)
	# SolarUI.CHARGE_EFFICIENCY / DISCHARGE_EFFICIENCY (script constants).
	ceff = 0.95
	deff = 0.95
	floor_kwh = float(solar.call("min_battery_kwh"))
	var sd: Variant = solar.get("battery_soc_shutdown_pct")
	var rs: Variant = solar.get("battery_soc_resume_pct")
	shutdown_kwh = maxf(floor_kwh, cap_kwh * (float(sd) if sd != null else 10.0) / 100.0)
	resume_kwh = cap_kwh * (float(rs) if rs != null else 20.0) / 100.0
	soc = clampf(cap_kwh * float(opts.get("start_soc", 0.8)), floor_kwh, cap_kwh)
	ac_on = soc > shutdown_kwh + 1e-6

	automations = AutomationSim.from_model(model)
	logic = ScadaLogicRun.from_data({"blocks": opts.get("logic", [])})
	alarms = ScadaAlarmRun.from_rules(opts.get("alarms", []))
	# The bridge makes a habitat's people on its first tick, so "has anybody"
	# is asked of the model, not of the bridge.
	for it: Dictionary in model.items_of_type("processor"):
		var hsp: Dictionary = it.get("specs", {})
		if str(hsp.get("role", "")) == "habitat" and bool(hsp.get("pop_driven", false)):
			_pop_driven = true
	flow.call("clear_timelines")
	sgv.call("_begin_sim_writes")
	flow.call("render_step", start_abs, 0.0, ac_on)
	sgv.call("_end_sim_writes")
	_seed_acc()
	_conn_flow = flow.get("_conn_flow")
	for c: Dictionary in model.connections:
		_conn_ends[str(c.get("id", ""))] = [str(c.get("source_item_id", "")), str(c.get("target_item_id", ""))]
	return ""


## Hand the world back (idempotent).
func release() -> void:
	if _released:
		return
	_released = true
	if sgv != null:
		sgv.call("set_ambient_flow_suspended", false)
	if main != null and main.has_method("pop_clock_claim"):
		main.call("pop_clock_claim", CLOCK_OWNER)
	if _live_engine != null and is_instance_valid(_live_engine):
		_live_engine.set_process(_live_engine_was)
	if solar != null and solar.has_method("reanchor_live_battery"):
		solar.call("reanchor_live_battery", soc)


func done() -> bool:
	return cursor >= end_abs - 1e-9


func progress() -> float:
	return clampf((cursor - start_abs) / maxf(end_abs - start_abs, 1e-6), 0.0, 1.0)


## The weather archive follows the sim year: when the cursor crosses into a
## new year, ask for it and wait (the caller awaits this between chunks).
func weather_year_due() -> int:
	var d: Dictionary = main.get("clock").call("abs_hours_to_date", cursor + step_h)
	var y := int(d.get("year", 0))
	return y if y != _year_loaded else 0


func mark_weather_year(y: int) -> void:
	_year_loaded = y


## Step up to `n` steps. Call inside nothing: it brackets its own sim writes.
func step_chunk(n: int) -> void:
	sgv.call("_begin_sim_writes")
	# The load-proxy host re-syncs every proxy on each model write unless told
	# a bulk write is on (the live ambient tick tells it; this did not, and
	# that was most of a step's cost). It syncs once at the end instead.
	var host: Node = sgv.get_node_or_null("GraphSimLoadHost")
	if host != null and host.has_method("begin_bulk_sync"):
		host.call("begin_bulk_sync")
	var stop := n
	while stop > 0 and not done():
		_step()
		stop -= 1
	if host != null and host.has_method("end_bulk_sync"):
		host.call("end_bulk_sync")
	sgv.call("_end_sim_writes")
	if sgv.has_method("_flush_sim_bulk_update"):
		sgv.call("_flush_sim_bulk_update")


func _step() -> void:
	var t0 := cursor
	var dt := minf(step_h, end_abs - cursor)
	var t1 := t0 + dt
	cursor = t1
	steps += 1
	var tm0 := Time.get_ticks_usec()

	# 1. Energy over [t0, t1]: the battery ExperimentEnergyRun models.
	var pair: Vector2 = solar.call("evaluate_solar_pair_at", t0 + dt * 0.5)
	var solar_kw := maxf(pair.y, 0.0)
	var raw_kw := maxf(pair.x, solar_kw)
	var demand_kw := GraphAcLoad.compute_watts_offline(model, false) / 1000.0
	var load_kw := demand_kw if ac_on else 0.0
	var aux_kw := maxf(dc_kw, 0.0)
	var headroom_kw := maxf(cap_kwh - soc, 0.0) / maxf(dt * ceff, 1e-9)
	var used_solar := minf(solar_kw, maxf(load_kw - aux_kw + headroom_kw, 0.0))
	soc = EnergyTimeline.step_soc(soc, used_solar, aux_kw, load_kw, dt, cap_kwh, ceff, deff, floor_kwh)
	energy["solar_kwh"] += used_solar * dt
	energy["raw_kwh"] += raw_kw * dt
	energy["curtailed_kwh"] += (raw_kw - used_solar) * dt
	energy["load_kwh"] += load_kw * dt
	energy["aux_kwh"] += aux_kw * dt
	if not ac_on:
		energy["ac_off_h"] += dt
	energy["min_soc_pct"] = minf(float(energy["min_soc_pct"]), 100.0 * soc / cap_kwh)
	if ac_on and soc <= shutdown_kwh + 1e-6:
		ac_on = false
		energy["ac_off_events"] = int(energy["ac_off_events"]) + 1
		_event(t1, "power", "AC shed: battery at %.0f %%" % (100.0 * soc / cap_kwh))
	elif not ac_on and soc >= resume_kwh - 1e-6:
		ac_on = true

	# 2. The clock every clock-reading tick sees.
	main.call("set_absolute_hours", t1)

	# 3. People (and through them the crew chores).
	var tp0 := Time.get_ticks_usec()
	if bridge != null and _pop_driven:
		bridge.call("tick_at", model, flow, main, t1)
	t_pop_us += Time.get_ticks_usec() - tp0

	# 4. Automations in sim time.
	if automations != null and not automations.is_empty():
		var numeric := {}
		var states := {}
		for it: Dictionary in model.items:
			var ity := str(it.get("type", ""))
			var iid := str(it.get("id", ""))
			var sp: Dictionary = it.get("specs", {})
			var nm := str(sp.get("name", "")).strip_edges().to_lower().replace(" ", "_")
			if ity == "resource":
				var pct := clampf(float(sp.get("level", 0.0)), 0.0, 1.0) * 100.0
				numeric["tank.%s.level" % iid] = pct
				if not nm.is_empty():
					numeric["tank.%s.level" % nm] = pct
			elif ity in ["processor", "appliance", "acload"]:
				var v := "on" if str(sp.get("requested_state", sp.get("current_state", "off"))).to_lower() == "on" else "off"
				states["node.%s" % iid] = v
		numeric["sensor.battery_level"] = 100.0 * soc / cap_kwh
		numeric["sensor.solar_power"] = solar_kw * 1000.0
		numeric["sensor.load_power"] = load_kw * 1000.0
		numeric["sensor.total_ac_load"] = load_kw * 1000.0
		var ctx := {"numeric": numeric, "states": states,
			"sun": Vector2(6.0, 18.0), "weekday": AutomationSim.weekday_of(t1)}
		auto_log_n += automations.step(t0, t1, ctx, _apply_command)

	var site_tags := {"sensor.battery_level": 100.0 * soc / cap_kwh,
		"sensor.solar_power": solar_kw * 1000.0, "sensor.load_power": load_kw * 1000.0}
	if logic != null and not logic.is_empty():
		logic.step(model, t1, site_tags, _apply_command)
	if alarms != null and not alarms.is_empty():
		alarms.step(func(tag: String) -> float:
			return logic.read(model, tag, site_tags) if logic != null else ScadaLogicRun.read_model(model, tag), t1)

	# 5. The view's machine ticks (rates the flow engine reads).
	if steps % _machine_tick_every == 0:
		for fn in ["_tick_graph_biodigester", "_tick_graph_tools",
				"_tick_graph_pp_extruder", "_tick_graph_pp_sheet_press"]:
			if sgv.has_method(fn):
				sgv.call(fn, 10.0)

	# 6. Resources with the AC state the battery just had.
	var tf0 := Time.get_ticks_usec()
	_conn_flow.clear()
	flow.call("render_step", t1, dt, ac_on)
	t_flow_us += Time.get_ticks_usec() - tf0
	# Gross throughput per store: the engine's own per-wire flows of this
	# step (a tank's timeline keeps only the NET). A batch's frontloaded
	# charge has no wire flow, so `out` can read low for a store that feeds one.
	for cid in _conn_flow:
		var rate := float((_conn_flow[cid] as Dictionary).get("rate", 0.0))
		if rate <= 0.0:
			continue
		var ct: Array = conn_tot.get(cid, [str((_conn_flow[cid] as Dictionary).get("kind", "")), 0.0])
		ct[1] = float(ct[1]) + rate * dt
		conn_tot[cid] = ct
		var ends: Array = _conn_ends.get(cid, [])
		if ends.is_empty():
			continue
		var ta: Dictionary = acc.get(ends[1], {})
		if not ta.is_empty() and ta["type"] == "tank":
			ta["in"] += rate * dt
		var sa: Dictionary = acc.get(ends[0], {})
		if not sa.is_empty() and sa["type"] == "tank":
			sa["out"] += rate * dt
	dc_kw = maxf(float(DcWiring.sum_graph_dc_generation_kw(model)), 0.0)

	_account(t1, dt)
	t_misc_us += Time.get_ticks_usec() - tm0


func _apply_command(item_id: String, command: Variant) -> void:
	var it := model.get_item(item_id)
	if it.is_empty():
		return
	var sp: Dictionary = it.get("specs", {})
	var on := str(sp.get("requested_state", sp.get("current_state", "off"))).to_lower() == "on"
	match str(command):
		"turn_on": on = true
		"turn_off": on = false
		"toggle": on = not on
	# The live game switches a graph load through its GraphSimLoad proxy (the
	# proxy's own requested state is what the host writes back to the model),
	# so an automation here must too.
	var dev := str(it.get("device_path", ""))
	var node: Node = main.get_node_or_null(NodePath(dev)) if not dev.is_empty() else null
	if node != null and node.has_method("turn_on") and node.has_method("turn_off"):
		node.call("turn_on" if on else "turn_off")
	sp = model.get_item(item_id).get("specs", {})
	sp["requested_state"] = "on" if on else "off"
	sp["current_state"] = sp["requested_state"]
	if acc.has(item_id):
		acc[item_id]["switches"] = int(acc[item_id].get("switches", 0)) + 1


func _event(t: float, kind: String, text: String) -> void:
	if events.size() < 400:
		events.append({"t": t, "day": (t - start_abs) / 24.0, "kind": kind, "text": text})


func _seed_acc() -> void:
	_feeds.clear()
	for c in GraphNesting.flat_connections(model):
		_feeds[str(c.get("source_item_id", ""))] = true
	for it: Dictionary in model.items:
		var iid := str(it.get("id", ""))
		var ity := str(it.get("type", ""))
		var sp: Dictionary = it.get("specs", {})
		var nm := str(sp.get("name", iid))
		if ity == "resource":
			if bool(it.get("is_virtual", false)) or iid.begins_with("virtual_"):
				continue
			var cap := float(sp.get("capacity_qty", 100.0))
			var lvl := clampf(float(sp.get("level", 0.0)), 0.0, 1.0)
			acc[iid] = {"type": "tank", "name": nm,
				"kind": ResourceKinds.normalize_kind(str(sp.get("resource_kind", ""))),
				"unit": str(sp.get("capacity_unit", "")), "cap": cap,
				"start": lvl * cap, "end": lvl * cap, "min": lvl * cap, "max": lvl * cap,
				"in": 0.0, "out": 0.0, "overflow": 0.0, "empty_h": 0.0, "full_h": 0.0,
				"feeds": _feeds.has(iid), "first_empty_day": -1.0}
		elif ity in ["processor", "plant", "catchment"]:
			acc[iid] = {"type": ity, "name": nm, "role": str(sp.get("role", "")),
				"running_h": 0.0, "blocked_h": 0.0, "starved_h": 0.0, "idle_h": 0.0,
				"kwh": 0.0, "reasons": {}, "switches": 0}


func _account(t: float, dt: float) -> void:
	var day := int(floor((t - start_abs - 1e-6) / 24.0))
	if day != _last_day:
		if _last_day >= 0:
			_close_day(t)
		_last_day = day
		_day_acc = {"solar": float(energy["solar_kwh"]), "load": float(energy["load_kwh"]),
			"ac_off": float(energy["ac_off_h"])}
	for it: Dictionary in model.items:
		var iid := str(it.get("id", ""))
		var a: Dictionary = acc.get(iid, {})
		if a.is_empty():
			continue
		var sp: Dictionary = it.get("specs", {})
		if a["type"] == "tank":
			var stock := clampf(float(sp.get("level", 0.0)), 0.0, 1.0) * float(a["cap"])
			a["end"] = stock
			if stock < float(a["min"]):
				a["min"] = stock
			if stock > float(a["max"]):
				a["max"] = stock
			var pct := stock / maxf(float(a["cap"]), 1e-9)
			if pct <= 0.001 and bool(a["feeds"]):
				a["empty_h"] += dt
				if float(a["first_empty_day"]) < 0.0:
					a["first_empty_day"] = (t - start_abs) / 24.0
					if str(a["kind"]) in ["water", "food"]:
						_event(t, "tank", "%s ran empty" % str(a["name"]))
			if pct >= 0.999:
				a["full_h"] += dt
		else:
			var st := str(sp.get("node_state", ""))
			match st:
				GraphNodeState.RUNNING:
					a["running_h"] += dt
					var w := float(it.get("batch_active_watts", sp.get("live_watts", sp.get("watts", 0.0))))
					a["kwh"] += w * dt / 1000.0
				GraphNodeState.BLOCKED:
					a["blocked_h"] += dt
					var r := str(sp.get("node_state_reason", "?"))
					(a["reasons"] as Dictionary)[r] = float((a["reasons"] as Dictionary).get(r, 0.0)) + dt
				GraphNodeState.STARVED:
					a["starved_h"] += dt
				_:
					a["idle_h"] += dt
			if str(a.get("role", "")) == "habitat":
				for k in (sp.get("starved_kinds", []) as Array):
					(people["starved_h"] as Dictionary)[str(k)] = float((people["starved_h"] as Dictionary).get(str(k), 0.0)) + dt
				for k2 in (sp.get("ideal_import_rates", {}) as Dictionary).keys():
					(people["ideal_import"] as Dictionary)[str(k2)] = float((people["ideal_import"] as Dictionary).get(str(k2), 0.0)) \
						+ float((sp["ideal_import_rates"] as Dictionary)[k2]) * dt
				for k3 in (sp.get("ideal_export_rates", {}) as Dictionary).keys():
					(people["ideal_export"] as Dictionary)[str(k3)] = float((people["ideal_export"] as Dictionary).get(str(k3), 0.0)) \
						+ float((sp["ideal_export_rates"] as Dictionary)[k3]) * dt
				if bridge != null and steps % 10 == 0:
					var s: Dictionary = bridge.call("summary_for", iid)
					if not s.is_empty():
						people["min_present"] = mini(int(people["min_present"]), int(s.get("count", 0)))
						people["min_morale"] = minf(float(people["min_morale"]), float(s.get("worst_morale", 1.0)))
						people["morale_sum"] += float(s.get("mean_morale", 0.0))
						people["samples"] = int(people["samples"]) + 1
						people["departures"] = maxi(int(people["departures"]), int(s.get("departures", 0)))
						people["last"] = s
						for nk in (s.get("blocked", {}) as Dictionary).keys():
							(people["blocked_h"] as Dictionary)[str(nk)] = float((people["blocked_h"] as Dictionary).get(str(nk), 0.0)) \
								+ float((s["blocked"] as Dictionary)[nk]) * dt * 10.0


func _close_day(t: float) -> void:
	var row := {"day": _last_day, "soc_pct": 100.0 * soc / cap_kwh,
		"solar_kwh": float(energy["solar_kwh"]) - float(_day_acc.get("solar", 0.0)),
		"load_kwh": float(energy["load_kwh"]) - float(_day_acc.get("load", 0.0)),
		"ac_off_h": float(energy["ac_off_h"]) - float(_day_acc.get("ac_off", 0.0)),
		"tanks": {}}
	for iid in acc:
		var a: Dictionary = acc[iid]
		if a["type"] == "tank":
			(row["tanks"] as Dictionary)[iid] = float(a["end"])
	var last: Dictionary = people.get("last", {})
	row["people"] = int(last.get("count", 0))
	row["morale"] = float(last.get("mean_morale", 0.0))
	daily.append(row)


## Overflow totals are on the tanks' timelines (the engine counts what the
## full-tank clamp discarded).
func finish() -> void:
	_close_day(cursor)
	for iid in acc:
		var a: Dictionary = acc[iid]
		if a["type"] != "tank":
			continue
		var tl: Object = flow.call("get_timeline", iid)
		if tl != null:
			a["overflow"] = float(tl.get("total_overflow_qty"))
		# A batch's frontloaded charge moves no wire flow, so the per-wire
		# `out` misses it: the store's own balance is the floor.
		a["out"] = maxf(float(a["out"]), float(a["start"]) + float(a["in"]) - float(a["end"]) - float(a["overflow"]))
