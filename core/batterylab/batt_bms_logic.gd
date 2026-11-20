class_name BattBmsLogic
extends RefCounted

## What a lithium BMS does every moment, as a state machine over what it
## reads: each series group's voltage (through the balance leads), the pack
## current (through its shunt) and its temperature sensors.
##
## Every protection is a (trip, release, delay_s) triple from BattBms.params:
## it TRIPS when its reading has been past `trip` for `delay_s` without a
## break, and RELEASES when the reading comes back past `release` (voltages and
## temperatures: hysteresis, so a cell sitting on the line does not chatter)
## or, for the current trips, after a recovery wait (`RECOVER_S`; most BMSs
## retry on their own).
##
## The BMS has two switches. A trip opens the one in BattBms.OPENS:
##   - charge switch open: no current can flow IN; loads still run (on a
##     common-port FET BMS the discharge current passes the open charge FET's
##     body diode);
##   - discharge switch open: no current can flow OUT; a charger can still
##     fill it (the same, the other way round).
## A short circuit opens both.
##
## Balancing: passive bleeders draw `a` amps from every group more than
## `delta_v` above the lowest, once the highest is above `start_v` and the
## pack is not being discharged; an active balancer moves `a` amps from the
## highest group to the lowest (at `ACTIVE_EFF`).
##
## State of charge is counted (coulomb counting through the shunt, with a
## small gain error) and set to 100 % when the pack is full (an over-voltage
## trip or the charger finishing) and to 0 % at an under-voltage trip, as
## real BMSs recalibrate.
##
## Pure: `step` takes and returns plain data, so the lab's simulation, the
## selftest and (later) the live graph can all run it.

## Seconds a current trip waits before it closes the switch again (typical
## auto-recovery; an estimate across BMS brands).
const RECOVER_S := 30.0
## A short circuit waits longer before it retries.
const SC_RECOVER_S := 60.0
## Pack current (A) that counts as charging / discharging rather than rest.
const REST_A := 0.5
## Active balancer efficiency (a capacitor / inductor transfer).
const ACTIVE_EFF := 0.9
## Coulomb counter gain error (the shunt + ADC), an estimate.
const SHUNT_GAIN_ERR := 0.005

const VOLT_TRIPS := ["cell_ov", "cell_uv"]
const CURRENT_TRIPS := ["charge_oc", "discharge_oc", "discharge_oc2", "short_circuit"]
const TEMP_TRIPS := ["charge_ot", "discharge_ot", "charge_ut", "discharge_ut"]


## A fresh BMS: both switches closed, nothing tripped, `soc` counted from.
static func new_state(soc: float = 0.5) -> Dictionary:
	var trips := {}
	var timers := {}
	var since := {}
	for k in BattBms.PROTECTIONS:
		trips[k] = false
		timers[k] = 0.0
		since[k] = -1.0
	return {"trips": trips, "timers": timers, "since": since, "chg": true, "dsg": true,
		"soc_est": clampf(soc, 0.0, 1.0), "balancing": false}


## The reading a protection compares, and whether "past" means above (+1)
## or below (-1) the trip. `rd` = {cell_v: PackedFloat64Array, i_a (+ in),
## t_max, t_min}; `cont_a` = the BMS's rating (current trips are × it).
static func _measure(key: String, rd: Dictionary, cont_a: float) -> Array:
	var cv: PackedFloat64Array = rd["cell_v"]
	var i := float(rd["i_a"])
	match key:
		"cell_ov":
			return [_max(cv), 1]
		"cell_uv":
			return [_min(cv), -1]
		"charge_oc":
			return [i / maxf(cont_a, 1e-9), 1]
		"discharge_oc", "discharge_oc2", "short_circuit":
			return [-i / maxf(cont_a, 1e-9), 1]
		"charge_ot", "discharge_ot":
			return [float(rd["t_max"]), 1]
		"charge_ut", "discharge_ut":
			return [float(rd["t_min"]), -1]
	return [0.0, 1]


static func _max(a: PackedFloat64Array) -> float:
	var m := -INF
	for v in a:
		m = maxf(m, v)
	return m


static func _min(a: PackedFloat64Array) -> float:
	var m := INF
	for v in a:
		m = minf(m, v)
	return m


## One step of `dt` seconds at time `t_s`. Updates `st` in place and returns
## the events [{key, what "trip" | "release", value, text}].
static func step(st: Dictionary, p: Dictionary, bms: Dictionary, rd: Dictionary, dt: float,
		t_s: float) -> Array:
	var events: Array = []
	if p.is_empty():
		return events
	var cont_a := float(bms.get("cont_a", 100.0))
	var trips: Dictionary = st["trips"]
	var timers: Dictionary = st["timers"]
	var since: Dictionary = st["since"]
	var i := float(rd["i_a"])
	for key in BattBms.PROTECTIONS:
		var lim: Dictionary = p.get(key, {})
		if lim.is_empty():
			continue
		var m := _measure(key, rd, cont_a)
		var v := float(m[0])
		var dir := int(m[1])
		var trip := float(lim["trip"])
		var rel := float(lim.get("release", trip))
		if not bool(trips[key]):
			var past := (v > trip) if dir > 0 else (v < trip)
			if past:
				timers[key] = float(timers[key]) + dt
				if float(timers[key]) >= float(lim.get("delay_s", 0.0)) - 1e-12:
					trips[key] = true
					since[key] = t_s
					timers[key] = 0.0
					events.append({"key": key, "what": "trip", "value": v,
						"text": "%s: %s" % [BattBms.WORDS[key], _switch_words(key, "open")]})
			else:
				timers[key] = 0.0
		else:
			var back := false
			if key in CURRENT_TRIPS:
				var wait := SC_RECOVER_S if key == "short_circuit" else RECOVER_S
				back = t_s - float(since[key]) >= wait
			elif key == "cell_uv":
				# Released by the cells coming back up, or by a charger.
				back = v > rel or i > REST_A
			elif key == "cell_ov":
				back = v < rel or i < -REST_A
			else:
				back = (v < rel) if dir > 0 else (v > rel)
			if back:
				trips[key] = false
				since[key] = -1.0
				events.append({"key": key, "what": "release", "value": v,
					"text": "%s cleared: %s" % [BattBms.WORDS[key], _switch_words(key, "close")]})
	st["chg"] = true
	st["dsg"] = true
	for key in trips:
		if not bool(trips[key]):
			continue
		var opens := str(BattBms.OPENS.get(key, "both"))
		if opens == "charge" or opens == "both":
			st["chg"] = false
		if opens == "discharge" or opens == "both":
			st["dsg"] = false
	# Coulomb counting and the recalibrations.
	var cap_ah := float(rd.get("cap_ah", 0.0))
	if cap_ah > 0.0:
		st["soc_est"] = clampf(float(st["soc_est"]) + i * (1.0 + SHUNT_GAIN_ERR) * dt / 3600.0 / cap_ah, 0.0, 1.0)
	for e in events:
		if str(e["what"]) == "trip" and str(e["key"]) == "cell_ov":
			st["soc_est"] = 1.0
		elif str(e["what"]) == "trip" and str(e["key"]) == "cell_uv":
			st["soc_est"] = 0.0
	return events


static func _switch_words(key: String, verb: String) -> String:
	match str(BattBms.OPENS.get(key, "both")):
		"charge":
			return "the charge switch %ss" % verb
		"discharge":
			return "the discharge switch %ss" % verb
	return "both switches %s" % verb


## The current the BMS lets through: charge blocked while the charge switch
## is open, discharge while the discharge switch is.
static func allowed_current(st: Dictionary, want_a: float) -> float:
	if want_a > 0.0 and not bool(st["chg"]):
		return 0.0
	if want_a < 0.0 and not bool(st["dsg"]):
		return 0.0
	return want_a


## Balance current per series group (A, + drawn out, − put in), for the
## group voltages `cell_v`, pack current `i_a` and the BMS's `bal`
## ({kind, a, start_v, delta_v} from BattBms.balance_for).
static func balance(bal: Dictionary, cell_v: PackedFloat64Array, i_a: float) -> PackedFloat64Array:
	var n := cell_v.size()
	var out := PackedFloat64Array()
	out.resize(n)
	var kind := str(bal.get("kind", "none"))
	var a := float(bal.get("a", 0.0))
	if kind == "none" or a <= 0.0 or n < 2:
		return out
	var hi := _max(cell_v)
	var lo := _min(cell_v)
	if hi < float(bal.get("start_v", 0.0)) or hi - lo <= float(bal.get("delta_v", 0.0)):
		return out
	if kind == "passive":
		if i_a < -REST_A:
			return out
		for g in n:
			if cell_v[g] > lo + float(bal["delta_v"]):
				out[g] = a
	else:
		var gh := 0
		var gl := 0
		for g in n:
			if cell_v[g] > cell_v[gh]:
				gh = g
			if cell_v[g] < cell_v[gl]:
				gl = g
		out[gh] = a
		out[gl] = -a * ACTIVE_EFF * cell_v[gh] / maxf(cell_v[gl], 0.1)
	return out


## Plain words for the state: "Charging and discharging allowed", or what is
## stopped and why.
static func describe(st: Dictionary) -> String:
	var tripped: Array = []
	for k in (st["trips"] as Dictionary):
		if bool(st["trips"][k]):
			tripped.append(str(BattBms.WORDS[k]))
	if tripped.is_empty():
		return "Both switches closed: it can charge and discharge."
	var parts: Array = []
	if not bool(st["chg"]):
		parts.append("charging stopped")
	if not bool(st["dsg"]):
		parts.append("discharging stopped")
	var head := ", ".join(PackedStringArray(parts))
	head = head.substr(0, 1).to_upper() + head.substr(1)
	return "%s (%s)." % [head, ", ".join(PackedStringArray(tripped))]
