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
	return w


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
		elif ity in ["processor", "appliance", "acload"]:
			_node_states["node.%s" % iid] = _on_off(sp)
			if not nm.is_empty():
				_node_states["node.%s" % nm] = _node_states["node.%s" % iid]


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


## ExperimentEnergyRun.before_step: run the automations over the last step.
func before_step(t: float, soc_kwh: float, _ac_on: bool) -> void:
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
	var aux := _held_aux
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
