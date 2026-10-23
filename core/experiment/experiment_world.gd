class_name ExperimentWorld
extends RefCounted

## One simulated world for an experiment: its OWN copy of the graph, with the
## graph's automations running on it in sim time (AutomationSim), feeding an
## ExperimentEnergyRun. Solar comes from SolarUI's pure evaluator (the site,
## its array and its weather); the AC load is read off the COPY after every
## switch (GraphAcLoad.compute_watts_offline), so a load an automation turns
## off at 23:00 draws nothing from 23:00 in this world and only this world.
##
## The live graph is never written: the copy is GraphModel.deserialize of
## its serialize(). Loads start as the player has them switched (requested
## state); the run sheds them itself at the battery floor.
##
## Optional `observed`: replay the real load instead (load_mode "observed"),
## and / or the real aux (aux_mode "observed").
##
## Resources (`enable_flow(host)`): the copy gets its OWN ResourceFlowEngine,
## stepped by the run with the run's AC state (render_step, weather and sun
## at each instant) — tanks fill and drain, processors run, block and starve,
## siphon / penstock turbines make power from the copy's ponds and streams.
## That feeds back: a running machine draws its watts (the load is re-read
## every step), tank levels and node states reach the automations, and the
## copy's graph DC generation (hydro into the bank) joins the battery
## (DcPowerWiring.sum_graph_dc_generation_kw, one step behind, as the
## pre-render does). The host is the live SystemGraphView, asked only
## read-only questions (terrain ponds, stream supply at an intake, stream
## inflows — matched to tanks by id, so a pond that exists only in a fork
## gets no stream). Not simulated: people (pop-driven habitats bill their
## authored headcount at the preset rates), the graph's wind / hydro
## ESTIMATOR nodes (held at their output now), camp power.

var model: GraphModel = null
var automations: AutomationSim = null
var solar_ui: Node = null
var observed: ExperimentSeries = null
var load_mode := ExperimentEvaluator.LOAD_MODEL
var aux_mode := ExperimentEvaluator.AUX_HELD
var losses_on := false

var _cap := 16.0
var _held_aux := 0.0
var _load_kw := 0.0
var _load_dirty := true
var _last_t := NAN
var _last_solar_kw := 0.0
var _last_load_kw := 0.0
var _sun_cache: Dictionary = {}     # day index -> Vector2
var _lat := 0.0
var _lon := 0.0
var _clock_ref: Object = null
var _tank_levels: Dictionary = {}
var _node_states: Dictionary = {}

var flow: ResourceFlowEngine = null
var _scene_aux := 0.0
var _dc_kw := 0.0
## Per-item accounting over the run (resource_summary()).
var _acc: Dictionary = {}       # item id -> {...}
var _acc_h := 0.0


## A world from a serialized graph (GraphModel.serialize()), or the live model.
static func from_graph(graph_data: Dictionary, su: Node, clock: Object) -> ExperimentWorld:
	var w := ExperimentWorld.new()
	w.model = GraphModel.new()
	w.model.deserialize(graph_data.duplicate(true))
	w.solar_ui = su
	w._clock_ref = clock
	if clock != null:
		w._lat = float(clock.get("latitude"))
		w._lon = float(clock.get("longitude"))
	w._cap = float(ExperimentEvaluator.battery_of(su)["cap_kwh"])
	if su != null and su.has_method("evaluate_aux_at"):
		w._held_aux = maxf(float(su.call("evaluate_aux_at", 0.0)), 0.0)
	var ctrl: Node = su.get_tree().root.get_node_or_null("SimSettingsController") \
		if su != null and su.is_inside_tree() else null
	w.losses_on = ctrl != null and bool(ctrl.get("connector_losses_enabled"))
	w._normalize_loads()
	w._snapshot_resources()
	w.automations = AutomationSim.from_model(w.model)
	if su != null:
		var sa: Variant = su.get("current_aux_generation_kw")
		w._scene_aux = maxf(float(sa), 0.0) if sa != null else 0.0
	return w


## Simulate the copy's resources too (see the header). `host` = the live
## SystemGraphView (its read-only world queries); null still runs the engine
## with no ponds or streams to ask about.
func enable_flow(host: Node) -> void:
	flow = ResourceFlowEngine.new()
	flow.setup(model, host)
	flow.connector_losses_override = 1 if losses_on else 0
	_dc_kw = maxf(DcPowerWiring.sum_graph_dc_generation_kw(model), 0.0)
	_acc.clear()
	_acc_h = 0.0


## The live world's graph, copied.
static func from_live(live_model: GraphModel, su: Node, clock: Object) -> ExperimentWorld:
	return from_graph(live_model.serialize() if live_model != null else {}, su, clock)


## A load's state is what the player asked for; whether the inverter serves
## it is the run's business (its own AC hysteresis).
func _normalize_loads() -> void:
	for it in model.items:
		if str(it.get("type", "")) not in ["appliance", "acload"]:
			continue
		var sp: Dictionary = it.get("specs", {})
		var req := str(sp.get("requested_state", "")).to_lower()
		if req == "on" or req == "off":
			sp["current_state"] = req


## Tank levels and node on / off for automations that read them (held from
## the start — the resource flow joins the run in a later milestone).
func _snapshot_resources() -> void:
	_tank_levels.clear()
	_node_states.clear()
	for it in model.items:
		var ity := str(it.get("type", ""))
		var iid := str(it.get("id", ""))
		var sp: Dictionary = it.get("specs", {})
		var nm := str(sp.get("name", "")).strip_edges().to_lower().replace(" ", "_")
		if ity == "resource":
			# specs.level is the 0..1 fill (ResourceFlowEngine.state_snapshot).
			var pct := clampf(float(sp.get("level", 0.0)), 0.0, 1.0) * 100.0
			_tank_levels["tank.%s.level" % iid] = pct
			if not nm.is_empty():
				_tank_levels["tank.%s.level" % nm] = pct
		elif ity in ["processor", "appliance", "acload", "habitat"]:
			# As get_automation_resource_context: on / off, escalated to the
			# flow engine's starved / blocked.
			var st := str(sp.get("node_state", ""))
			var v := _on_off(sp)
			if st == GraphNodeState.STARVED:
				v = "starved"
			elif st == GraphNodeState.BLOCKED:
				v = "blocked"
			_node_states["node.%s" % iid] = v
			if not nm.is_empty():
				_node_states["node.%s" % nm] = v


static func _on_off(sp: Dictionary) -> String:
	return "on" if str(sp.get("requested_state", sp.get("current_state", "off"))).to_lower() == "on" else "off"


## Switch a load on this world's copy (an automation action).
func apply_command(item_id: String, command: String) -> void:
	var it := model.get_item(item_id)
	if it.is_empty():
		return
	var sp: Dictionary = it.get("specs", {})
	var on := _on_off(sp) == "on"
	match command:
		"turn_on": on = true
		"turn_off": on = false
		"toggle": on = not on
	var s := "on" if on else "off"
	sp["requested_state"] = s
	sp["current_state"] = s
	_node_states["node.%s" % item_id] = s
	var nm := str(sp.get("name", "")).strip_edges().to_lower().replace(" ", "_")
	if not nm.is_empty():
		_node_states["node.%s" % nm] = s
	_load_dirty = true


## ExperimentEnergyRun.before_step: the resources over the last step (with
## the AC state the battery had), then the automations at `t`.
func before_step(t: float, soc_kwh: float, ac_on: bool) -> void:
	if flow != null:
		var dt := 0.0 if is_nan(_last_t) else maxf(t - _last_t, 0.0)
		flow.render_step(t, dt, ac_on)
		_dc_kw = maxf(DcPowerWiring.sum_graph_dc_generation_kw(model), 0.0)
		_load_dirty = true   # a machine that started or stopped draws differently
		_snapshot_resources()
		_account(dt)
	if automations != null and not automations.is_empty():
		var t0 := t if is_nan(_last_t) else _last_t
		var numeric := _tank_levels.duplicate()
		numeric["sensor.battery_level"] = 100.0 * soc_kwh / maxf(_cap, 1e-6)
		numeric["sensor.solar_power"] = _last_solar_kw * 1000.0
		numeric["sensor.load_power"] = _last_load_kw * 1000.0
		numeric["sensor.total_ac_load"] = _last_load_kw * 1000.0
		var ctx := {"numeric": numeric, "states": _node_states, "sun": sun_times(t),
			"weekday": weekday(t)}
		automations.step(t0, t, ctx, apply_command)
	_last_t = t


## ExperimentEnergyRun inputs at an instant.
func inputs_at(abs_h: float) -> Dictionary:
	var pair := Vector2.ZERO
	if solar_ui != null and solar_ui.has_method("evaluate_solar_pair_at"):
		pair = solar_ui.call("evaluate_solar_pair_at", abs_h)
	if _load_dirty:
		_load_kw = GraphAcLoad.compute_watts_offline(model, losses_on) / 1000.0
		_load_dirty = false
	var load := _load_kw
	if load_mode == ExperimentEvaluator.LOAD_OBSERVED and observed != null:
		var v := observed.value_at("load_kw", abs_h)
		if not is_nan(v):
			load = v
	# With the copy's resources simulated, the graph's own DC generators
	# (hydro into the bank) come from the copy; scene sources stay held.
	var aux := _held_aux if flow == null else _scene_aux + _dc_kw
	if aux_mode == ExperimentEvaluator.AUX_OBSERVED:
		aux = 0.0
		if observed != null:
			var a := observed.value_at("aux_kw", abs_h)
			if not is_nan(a):
				aux = a
	elif aux_mode == ExperimentEvaluator.AUX_NONE:
		aux = 0.0
	_last_solar_kw = pair.y
	_last_load_kw = load
	return {"solar_kw": pair.y, "raw_kw": pair.x, "aux_kw": aux, "load_kw": load}


## Sunrise / sunset (site clock hours) on the day of `abs_h`.
func sun_times(abs_h: float) -> Vector2:
	var di := int(floor(abs_h / 24.0))
	if _sun_cache.has(di):
		return _sun_cache[di]
	var v := Vector2(6.0, 18.0)
	if _clock_ref != null:
		var d: Dictionary = _clock_ref.call("abs_hours_to_date", float(di) * 24.0 + 12.0)
		var c := CelestialClock.new()
		c.latitude = _lat
		c.longitude = _lon
		c.year = int(d.get("year", 2026))
		c.month = int(d.get("month", 1))
		c.day = int(d.get("day", 1))
		c.day_time = 12.0
		v = Vector2(c.sunrise_hour, c.sunset_hour)
	_sun_cache[di] = v
	return v


static func weekday(abs_h: float) -> int:
	return AutomationSim.weekday_of(abs_h)


# --- resource accounting ----------------------------------------------------------

## Per tank: start / end / lowest fill, hours empty (≤ 1 % — only for a tank
## wired to feed something) and full (≥ 99 %).
## Per processor / habitat: hours running, blocked, starved.
func _account(dt: float) -> void:
	if dt <= 0.0:
		_seed_acc()
		return
	_acc_h += dt
	for it in model.items:
		var iid := str(it.get("id", ""))
		var ity := str(it.get("type", ""))
		var sp: Dictionary = it.get("specs", {})
		if ity == "resource":
			var a: Dictionary = _acc.get(iid, {})
			if a.is_empty():
				continue
			var pct := clampf(float(sp.get("level", 0.0)), 0.0, 1.0) * 100.0
			a["end_pct"] = pct
			a["min_pct"] = minf(float(a["min_pct"]), pct)
			# Empty matters only for a tank something draws from.
			if pct <= 1.0 and bool(a.get("feeds", false)):
				a["empty_h"] = float(a["empty_h"]) + dt
			if pct >= 99.0:
				a["full_h"] = float(a["full_h"]) + dt
		elif ity in ["processor", "habitat"]:
			var b: Dictionary = _acc.get(iid, {})
			if b.is_empty():
				continue
			match str(sp.get("node_state", "")):
				GraphNodeState.RUNNING:
					b["running_h"] = float(b["running_h"]) + dt
				GraphNodeState.BLOCKED:
					b["blocked_h"] = float(b["blocked_h"]) + dt
				GraphNodeState.STARVED:
					b["starved_h"] = float(b["starved_h"]) + dt


func _seed_acc() -> void:
	if not _acc.is_empty():
		return
	var feeds := {}
	for c in GraphNesting.flat_connections(model):
		feeds[str(c.get("source_item_id", ""))] = true
	for it in model.items:
		var iid := str(it.get("id", ""))
		var ity := str(it.get("type", ""))
		var sp: Dictionary = it.get("specs", {})
		var nm := str(sp.get("name", iid))
		if ity == "resource":
			# Sources without a level (stream intakes, unlimited supplies, the
			# solar bridge's virtual items) are not tanks to run dry.
			if bool(sp.get("is_virtual", false)) or str(iid).begins_with("virtual_") 					or bool(sp.get("unlimited_capacity", false)) or bool(sp.get("stream_source", false)):
				continue
			var pct := clampf(float(sp.get("level", 0.0)), 0.0, 1.0) * 100.0
			_acc[iid] = {"kind": "tank", "name": nm,
				"resource": ResourceKinds.normalize_kind(str(sp.get("resource_kind", ""))),
				"start_pct": pct, "end_pct": pct, "min_pct": pct, "empty_h": 0.0, "full_h": 0.0,
				"feeds": feeds.has(iid)}
		elif ity in ["processor", "habitat"]:
			_acc[iid] = {"kind": ity, "name": nm, "running_h": 0.0, "blocked_h": 0.0, "starved_h": 0.0}


## {hours, tanks: {id: {...}}, machines: {id: {...}}, totals: {tank_empty_h,
## machine_down_h, machine_run_h}} — empty when resources were not simulated.
func resource_summary() -> Dictionary:
	if flow == null:
		return {}
	var tanks := {}
	var machines := {}
	var empty_h := 0.0
	var down_h := 0.0
	var run_h := 0.0
	for iid in _acc:
		var a: Dictionary = _acc[iid]
		if str(a["kind"]) == "tank":
			tanks[iid] = a.duplicate()
			empty_h += float(a["empty_h"])
		else:
			machines[iid] = a.duplicate()
			down_h += float(a["blocked_h"]) + float(a["starved_h"])
			run_h += float(a["running_h"])
	return {"hours": _acc_h, "tanks": tanks, "machines": machines,
		"totals": {"tank_empty_h": empty_h, "machine_down_h": down_h, "machine_run_h": run_h}}
