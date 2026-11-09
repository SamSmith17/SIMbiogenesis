class_name TcProcControl
extends RefCounted

## The sensors and actuators of a TC design in the Process Lab, as Home
## Assistant-shaped entities, and the bridge between the design's automations
## (the inspector's WHEN / IF / THEN cards, stored as `process.automations`)
## and the model (Phase 5b of plans/TC_PROCESS_LAB_PLAN.md).
##
## Entities (`<s>` = the design's name as a slug):
##   sensor.<s>_charge_max_temp / _charge_mean_temp   °C   the charge
##   sensor.<s>_moisture_left / _char                  kg
##   sensor.<s>_vessel_temp °C, sensor.<s>_vessel_pressure kPa (gauge)
##   sensor.<s>_<part>_temp                            °C   each element
##   sensor.<s>_<part>                                 a thermometer, a
##        gauge or a thermowell on the assembly reads the volume it sits on
##   sensor.<s>_<part>_level                           %    a sight glass
##   sensor.<s>_<ref>_level                            %    a drain's trap
##   sensor.<s>_cooling_out_temp °C, _gas_out L/min, _gas_lhv MJ/Nm³,
##        _condensate kg, _energy_in kWh
##   sensor.<s>_<name>     a probe the player dropped on a volume
##        (process.sensors: {name, kind temp|pressure|level|<species>, part})
##   switch.<s>_<part>                 an element / a valve
##   number.<s>_<part>_power           an element's watts
##   switch.<s>_heaters                every element
##   switch.<s>_cooling, number.<s>_cooling_flow   L/min
##   switch.<s>_<ref>_drain            a drain's valve
## A rule's scene_node action with no target switches every element (the
## design is the rule's one "item"); with a target it switches that one.
##
## Automations run inside the model on its own clock every AUTO_EVERY_S, so
## "elements off at 450 °C, back on at 420 °C" holds at any lab speed and in
## a pre-run. Clock times count from the lab's start hour.

const ITEM := "tc"
const AUTO_EVERY_S := 30.0
const PROBE_KINDS := [["temp", "Temperature"], ["pressure", "Pressure"], ["level", "Liquid level"],
	["H2O", "Water vapour %"], ["CO", "Carbon monoxide %"], ["H2", "Hydrogen %"], ["CH4", "Methane %"],
	["CO2", "Carbon dioxide %"], ["O2", "Oxygen %"]]
const UNIT := {"temp": "°C", "pressure": "kPa", "level": "%"}


static func slug(s: String) -> String:
	var o := ""
	for ch in s.to_lower():
		var c := ch.unicode_at(0)
		if (c >= 97 and c <= 122) or (c >= 48 and c <= 57):
			o += ch
		elif not o.ends_with("_"):
			o += "_"
	o = o.strip_edges().trim_prefix("_").trim_suffix("_")
	if o.length() > 32:
		o = o.substr(0, 32).trim_suffix("_")
	return o if o != "" else "tc_design"


static func design_slug(d: Dictionary) -> String:
	return slug(str((d.get("spec", {}) as Dictionary).get("name", "tc design")))


static func _part_label(d: Dictionary, pid: String) -> String:
	var pd: Dictionary = ((d.get("res", {}) as Dictionary).get("parts", {}) as Dictionary).get(pid, {})
	var b: Dictionary = pd.get("built", {})
	var lab := str(b.get("label", ""))
	if lab == "":
		lab = TcParts.label_of(str(b.get("type", ""))) if b.has("type") else pid
	return "%s (%s)" % [lab, pid]


## Every numeric sensor: [{key, label, unit, src}].
static func sensors(sim: TcProcSim, d: Dictionary, proc: Dictionary) -> Array:
	var s := design_slug(d)
	var out: Array = []
	var add := func(k: String, label: String, unit: String, src: Dictionary) -> void:
		out.append({"key": "sensor.%s_%s" % [s, k], "label": label, "unit": unit, "src": src})
	if sim.bed != null and not sim.bed.is_empty():
		add.call("charge_max_temp", "Hottest charge", "°C", {"kind": "bed_max"})
		add.call("charge_mean_temp", "Charge, mean", "°C", {"kind": "bed_mean"})
		add.call("moisture_left", "Water left in the charge", "kg", {"kind": "bed_moisture"})
		add.call("char", "Char made", "kg", {"kind": "bed_char"})
		add.call("charge_done", "Charge converted", "%", {"kind": "bed_done"})
		add.call("charge_mass", "Charge mass", "kg", {"kind": "bed_mass"})
	if sim.vessel_cv >= 0:
		add.call("vessel_temp", "Vessel gas", "°C", {"kind": "cv_t", "cv": sim.vessel_cv})
		add.call("vessel_pressure", "Vessel pressure", "kPa", {"kind": "cv_p", "cv": sim.vessel_cv})
	for k in sim.heater_parts.size():
		var pid := str(sim.heater_parts[k])
		add.call("%s_temp" % pid, "%s temperature" % _part_label(d, pid), "°C", {"kind": "element", "i": k})
	var cvs: Array = sim.net["cvs"]
	for i in cvs.size():
		var cv: Dictionary = cvs[i]
		for a in cv.get("probes", []):
			var role := str(a["role"])
			var pid2 := str(a["part"])
			if role == "probe_p":
				add.call(pid2, _part_label(d, pid2), "kPa", {"kind": "cv_p", "cv": i})
			else:
				add.call(pid2, _part_label(d, pid2), "°C", {"kind": "cv_t", "cv": i})
		if str(cv["role"]) == "sight":
			var sp := str((cv["parts"] as Array)[0]) if not (cv["parts"] as Array).is_empty() else "sight%d" % i
			add.call("%s_level" % sp, "%s level" % _part_label(d, sp), "%", {"kind": "cv_level", "cv": i})
	for b in sim.net["boundaries"]:
		if str(b["role"]) == "drain" and int(b["cv"]) >= 0:
			var nm := str(b["text"]) if str(b["text"]) != "" else str(b["ref"])
			add.call("%s_level" % slug(str(b["ref"])), "Liquid above %s (%s)" % [nm, b["ref"]], "%", {"kind": "cv_level", "cv": int(b["cv"])})
	if not sim.cool_lpm.is_empty():
		add.call("cooling_out_temp", "Cooling water out", "°C", {"kind": "cool_out"})
	# Gas out of a labelled outlet (none on a chain whose gas goes to units).
	var has_product := false
	for b2 in sim.net["boundaries"]:
		has_product = has_product or str(b2["role"]) == "product"
	if has_product or sim.units.is_empty():
		add.call("gas_out", "Gas out", "L/min", {"kind": "gas_out"})
		add.call("gas_lhv", "Gas heating value", "MJ/Nm³", {"kind": "gas_lhv"})
	add.call("condensate", "Condensate collected", "kg", {"kind": "condensate"})
	add.call("energy_in", "Energy in", "kWh", {"kind": "energy_in"})
	var has_engine := false
	for k2 in sim.units.size():
		var u: Dictionary = sim.units[k2]
		var up := str(u.get("part", ""))
		match str(u["kind"]):
			"holder":
				add.call("%s_level" % up, "%s fill" % _part_label(d, up), "%", {"kind": "holder", "i": k2})
				add.call("%s_lhv" % up, "Gas in %s" % _part_label(d, up), "MJ/Nm³", {"kind": "cv_lhv", "cv": int(u["cv"])})
			"dryer":
				add.call("%s_saturation" % up, "%s spent" % _part_label(d, up), "%", {"kind": "dryer", "i": k2})
			"engine":
				has_engine = true
				add.call("%s_power" % up, "%s output" % _part_label(d, up), "kW", {"kind": "engine", "part": up})
	if has_engine:
		add.call("electricity", "Electricity made", "kWh", {"kind": "engine_kwh"})
	for ps in proc.get("sensors", []):
		if not (ps is Dictionary):
			continue
		var pid3 := str(ps.get("part", ""))
		var cvi := _cv_of_part(sim, pid3)
		if cvi < 0:
			continue
		var kind := str(ps.get("kind", "temp"))
		var unit := str(UNIT.get(kind, "%"))
		var src := {"kind": "cv_t", "cv": cvi}
		match kind:
			"pressure":
				src = {"kind": "cv_p", "cv": cvi}
			"level":
				src = {"kind": "cv_level", "cv": cvi}
			"temp":
				pass
			_:
				src = {"kind": "cv_x", "cv": cvi, "species": kind}
		var nm2 := str(ps.get("name", "probe"))
		add.call(slug(nm2), "%s (probe)" % nm2, unit, src)
	return out


static func _cv_of_part(sim: TcProcSim, pid: String) -> int:
	for circ in ["product", "main", ""]:
		var c := TcProcNet.cv_of_part(sim.net, pid, circ) if circ != "" else TcProcNet.cv_of_part(sim.net, pid)
		if c >= 0:
			return c
	for i in sim.n_cv:
		for a in sim.net["cvs"][i]["attach"]:
			if str(a["part"]) == pid:
				return i
	return -1


## The values of `list` (or only the keys in `only`, when not empty).
static func read_all(sim: TcProcSim, list: Array, only: Dictionary = {}) -> Dictionary:
	var out := {}
	var tot := {}
	for e in list:
		var key := str(e["key"])
		if not only.is_empty() and not only.has(key):
			continue
		var src: Dictionary = e["src"]
		var kind := str(src["kind"])
		if kind.begins_with("bed_") and tot.is_empty():
			tot = sim.bed.totals()
		var v := NAN
		match kind:
			"bed_max":
				v = float(tot["t_max_k"]) - 273.15
			"bed_mean":
				v = float(tot["t_mean_k"]) - 273.15
			"bed_moisture":
				v = float(tot["moisture_kg"])
			"bed_char":
				v = float(tot["char_kg"])
			"bed_done":
				v = float(tot["pyro_frac"]) * 100.0
			"bed_mass":
				v = sim.bed.mass_kg()
			"cv_t":
				v = sim.gas_t(int(src["cv"])) - 273.15
			"cv_p":
				v = (sim.p_cv[int(src["cv"])] - TcSpecies.P_ATM) * 0.001
			"cv_level":
				var i := int(src["cv"])
				var vol := maxf(float(sim.net["cvs"][i]["volume_m3"]), 1e-9)
				v = clampf(sim._liq_volume(sim.liq[i]) / vol * 100.0, 0.0, 100.0)
			"cv_x":
				var i2 := int(src["cv"])
				var g: PackedFloat64Array = sim.gas[i2]
				var n := 0.0
				for x in g:
					n += x
				var si := TcProcSim.SP.find(str(src["species"]))
				v = g[si] / n * 100.0 if n > 0.0 and si >= 0 else 0.0
			"element":
				var k := int(src["i"])
				v = float(sim.element_t[k]) - 273.15 if k < sim.element_t.size() else NAN
			"cool_out":
				v = -INF
				for c in sim.cool_lpm.keys():
					v = maxf(v, sim.t_cool[int(c)] - 273.15)
			"gas_out":
				var pr := 0.0
				for x in sim.product_rate:
					pr += x
				v = pr * 0.022414 * 1000.0 * 60.0
			"gas_lhv":
				var pr2 := 0.0
				for x in sim.product_rate:
					pr2 += x
				v = TcThermo.lhv_mj_per_nm3(sim._dict(sim.product_rate)) if pr2 > 0.0 else 0.0
			"condensate":
				v = 0.0
				for si in TcProcSim.NS:
					v += sim.drained_mol[si] * TcSpecies.molar_mass_kg(str(TcProcSim.SP[si]))
			"energy_in":
				v = sim.e_in / 3.6e6
			"holder":
				v = sim.holder_fill(sim.units[int(src["i"])]) * 100.0
			"dryer":
				var du: Dictionary = sim.units[int(src["i"])]
				v = sim.ads_mol[int(du["cv"])] / maxf(float(du["cap_mol"]), 1e-12) * 100.0
			"engine":
				v = float(sim.engine_kw.get(str(src["part"]), 0.0))
			"engine_kwh":
				v = sim.engine_kwh
			"cv_lhv":
				v = sim._lhv_of(sim.gas[int(src["cv"])]) * 1.0e-6 / 0.022414
		if is_finite(v):
			out[key] = v
	return out


## Every actuator: [{key, label, kind: "switch"|"number", act, min?, max?,
## step?, unit?}]. `act` is the model's set_actuator id.
static func actuators(sim: TcProcSim, d: Dictionary, proc: Dictionary) -> Array:
	var s := design_slug(d)
	var out: Array = []
	for pid in sim.heater_parts:
		var lab := _part_label(d, str(pid))
		var w := float(TcProcSpec.heater(proc, str(pid))["w"])
		out.append({"key": "switch.%s_%s" % [s, pid], "label": lab, "kind": "switch", "act": "heater:%s" % pid})
		out.append({"key": "number.%s_%s_power" % [s, pid], "label": "%s power" % lab, "kind": "number",
			"act": "heater:%s" % pid, "min": 0.0, "max": maxf(2000.0, w * 2.0), "step": 25.0, "unit": "W"})
	if sim.heater_parts.size() > 1:
		out.append({"key": "switch.%s_heaters" % s, "label": "Every element", "kind": "switch", "act": "heaters"})
	var seen := {}
	for l in sim.net["links"]:
		if str(l["kind"]) == "valve" and str(l["part"]) != "" and not seen.has(str(l["part"])):
			seen[str(l["part"])] = true
			out.append({"key": "switch.%s_%s" % [s, l["part"]], "label": _part_label(d, str(l["part"])), "kind": "switch",
				"act": "valve:%s" % l["part"]})
	if not sim.cool_lpm.is_empty():
		out.append({"key": "switch.%s_cooling" % s, "label": "Cooling water", "kind": "switch", "act": "cooling_switch"})
		out.append({"key": "number.%s_cooling_flow" % s, "label": "Cooling water flow", "kind": "number", "act": "cooling",
			"min": 0.0, "max": 20.0, "step": 0.1, "unit": "L/min"})
	for bi in sim.drain_open.keys():
		var b: Dictionary = sim.net["boundaries"][int(bi)]
		var nm := str(b["text"]) if str(b["text"]) != "" else str(b["ref"])
		out.append({"key": "switch.%s_%s_drain" % [s, slug(str(b["ref"]))], "label": "%s valve (%s)" % [nm, b["ref"]], "kind": "switch",
			"act": "drain:%s" % b["ref"]})
	for u in sim.units:
		if str(u["kind"]) == "engine":
			var ep := str(u.get("part", ""))
			out.append({"key": "switch.%s_%s" % [s, ep], "label": _part_label(d, ep), "kind": "switch", "act": "engine:%s" % ep})
	return out


## on / off of every switch (the automations' state signals).
static func states(sim: TcProcSim, acts: Array) -> Dictionary:
	var out := {}
	for a in acts:
		if str(a["kind"]) != "switch":
			continue
		out[str(a["key"])] = "on" if is_on(sim, str(a["act"])) else "off"
	return out


static func is_on(sim: TcProcSim, act: String) -> bool:
	var sp := act.split(":", true, 1)
	var key := sp[1] if sp.size() > 1 else ""
	match sp[0]:
		"heater":
			return bool(sim.heater_on.get(key, true)) and float(sim.heater_w.get(key, 0.0)) > 0.0
		"heaters":
			for p in sim.heater_parts:
				if is_on(sim, "heater:%s" % p):
					return true
			return false
		"valve":
			for li in (sim.net["links"] as Array).size():
				if str(sim.net["links"][li]["part"]) == key:
					return bool(sim.link_open[li])
			return false
		"cooling_switch":
			for c in sim.cool_lpm.keys():
				if float(sim.cool_lpm[c]) > 0.0:
					return true
			return false
		"drain":
			for bi in sim.drain_open.keys():
				if str(sim.net["boundaries"][int(bi)]["ref"]) == key:
					return bool(sim.drain_open[bi])
		"engine":
			return bool(sim.engine_on.get(key, false))
	return false


static func value_of(sim: TcProcSim, a: Dictionary) -> float:
	var act := str(a["act"])
	if act.begins_with("heater:"):
		return float(sim.heater_w.get(act.substr(7), 0.0))
	if act == "cooling":
		for c in sim.cool_lpm.keys():
			return float(sim.cool_lpm[c])
	return 0.0


## Apply one automation command (AutomationSim rich_commands) to the model.
## base_lpm: the cooling flow a switch turns back on to. Returns what it did,
## in words ("" when nothing matched).
static func apply(sim: TcProcSim, acts: Array, cmd: Variant, base_lpm: float, base_w: Dictionary) -> String:
	if cmd is String:
		cmd = {"cmd": cmd, "target": ""}
	var c: Dictionary = cmd
	var what := str(c.get("cmd", ""))
	if what == "set_value":
		var eid := str(c.get("entity_id", ""))
		for a in acts:
			if str(a["key"]) == eid and str(a["kind"]) == "number":
				var v := clampf(float(c.get("value", 0.0)), float(a.get("min", 0.0)), float(a.get("max", 1.0e9)))
				sim.set_actuator(str(a["act"]), v)
				return "%s → %s %s" % [str(a["label"]), _fmt(v), str(a.get("unit", ""))]
		return ""
	var target := str(c.get("target", ""))
	var act := "heaters" if target == "" else ""
	var label := "every element"
	for a in acts:
		if str(a["key"]) == target and str(a["kind"]) == "switch":
			act = str(a["act"])
			label = str(a["label"])
	if act == "":
		return ""
	var on := what == "turn_on"
	if what == "toggle":
		on = not is_on(sim, act)
	_switch(sim, act, on, base_lpm, base_w)
	return "%s %s" % [label, "on" if on else "off"]


static func _switch(sim: TcProcSim, act: String, on: bool, base_lpm: float, base_w: Dictionary) -> void:
	if act == "heaters":
		for p in sim.heater_parts:
			_switch(sim, "heater:%s" % p, on, base_lpm, base_w)
		return
	if act.begins_with("heater:"):
		var pid := act.substr(7)
		if on and float(sim.heater_w.get(pid, 0.0)) <= 0.0:
			sim.heater_w[pid] = float(base_w.get(pid, 600.0))
		sim.set_actuator(act, on)
	elif act == "cooling_switch":
		sim.set_actuator("cooling", base_lpm if on else 0.0)
	else:
		sim.set_actuator(act, on)


static func _fmt(v: float) -> String:
	return str(int(round(v))) if absf(v - round(v)) < 1e-6 else "%.2f" % v


## The entity ids the rules read (only these are measured each pass).
static func needed(autos: Array) -> Dictionary:
	var out := {}
	for a in autos:
		if not (a is Dictionary):
			continue
		for k in ["triggers", "conditions"]:
			for t in (a as Dictionary).get(k, []):
				if t is Dictionary and (t as Dictionary).has("entity_id"):
					out[str(t["entity_id"])] = true
	return out


# ---------------------------------------------------------------------------
# Presets and Home Assistant
# ---------------------------------------------------------------------------

## Ready-made rules for this design (the card editor's "+ Preset" menu).
static func templates(sim: TcProcSim, d: Dictionary) -> Array:
	var s := design_slug(d)
	var out: Array = []
	if sim.bed != null and not sim.bed.is_empty():
		var hot := "sensor.%s_charge_max_temp" % s
		# Off at once above 450 °C, back on only after a minute below 400 °C:
		# the hottest point sits next to an element and swings fast, and a
		# narrow band switches every minute or so.
		out.append({"label": "Hold the charge near 450 °C", "specs": [
			{"alias": "Elements off at 450 °C", "enabled": true,
				"triggers": [{"kind": "numeric", "entity_id": hot, "above": 450.0}],
				"conditions": [], "actions": [{"kind": "scene_node", "command": "turn_off"}]},
			{"alias": "Elements back on below 400 °C", "enabled": true,
				"triggers": [{"kind": "numeric", "entity_id": hot, "below": 400.0, "for_seconds": 60.0}],
				# Not once the charge is done: then it is left to cool.
				"conditions": [{"kind": "numeric", "entity_id": "sensor.%s_charge_done" % s, "below": 97.0}],
				"actions": [{"kind": "scene_node", "command": "turn_on"}]}]})
		out.append({"label": "Elements off when the charge is done", "specs": [done_rule(s)]})
		var to_outlet := false
		for b0 in sim.net["boundaries"]:
			to_outlet = to_outlet or str(b0["role"]) == "product"
		if to_outlet or sim.units.is_empty():
			out.append({"label": "Stop when the gas stops", "specs": [
				{"alias": "Elements off when the batch is done", "enabled": true,
					"triggers": [{"kind": "numeric", "entity_id": "sensor.%s_gas_out" % s, "below": 0.5, "for_seconds": 1800.0}],
					"conditions": [{"kind": "numeric", "entity_id": "sensor.%s_moisture_left" % s, "below": 0.05}],
					"actions": [{"kind": "scene_node", "command": "turn_off"}]}]})
	for b in sim.net["boundaries"]:
		if str(b["role"]) == "drain" and int(b["cv"]) >= 0:
			var r := slug(str(b["ref"]))
			out.append({"label": "Empty the trap at %s when it fills" % (str(b["text"]) if str(b["text"]) != "" else str(b["ref"])), "specs": [
				{"alias": "Drain %s at 80 %%" % b["ref"], "enabled": true,
					"triggers": [{"kind": "numeric", "entity_id": "sensor.%s_%s_level" % [s, r], "above": 80.0}],
					"conditions": [], "actions": [{"kind": "scene_node", "command": "turn_on", "target": "switch.%s_%s_drain" % [s, r]},
						{"kind": "delay", "delay_seconds": 120.0},
						{"kind": "scene_node", "command": "turn_off", "target": "switch.%s_%s_drain" % [s, r]}]}]})
			break
	# A genset fed from a gas holder: run it while the bell is well up, stop
	# before the holder is empty (an engine starved of gas stalls).
	var holder := ""
	var engine := ""
	for u in sim.units:
		if str(u["kind"]) == "holder" and holder == "":
			holder = str(u.get("part", ""))
		elif str(u["kind"]) == "engine" and engine == "":
			engine = str(u.get("part", ""))
	if holder != "" and engine != "":
		var lvl := "sensor.%s_%s_level" % [s, holder]
		var sw := "switch.%s_%s" % [s, engine]
		out.append({"label": "Run the genset from the gas holder", "specs": [
			{"alias": "Genset on when the holder is 60 % full", "enabled": true,
				"triggers": [{"kind": "numeric", "entity_id": lvl, "above": 60.0}],
				"conditions": [], "actions": [{"kind": "scene_node", "command": "turn_on", "target": sw}]},
			{"alias": "Genset off when the holder is down to 15 %", "enabled": true,
				"triggers": [{"kind": "numeric", "entity_id": lvl, "below": 15.0}],
				"conditions": [], "actions": [{"kind": "scene_node", "command": "turn_off", "target": sw}]}]})
	if not sim.cool_lpm.is_empty():
		out.append({"label": "More cooling water when it runs hot", "specs": [
			{"alias": "Cooling up when the water leaves above 45 °C", "enabled": true,
				"triggers": [{"kind": "numeric", "entity_id": "sensor.%s_cooling_out_temp" % s, "above": 45.0}],
				"conditions": [], "actions": [{"kind": "set_value", "entity_id": "number.%s_cooling_flow" % s, "value": 6.0}]}]})
	return out


## The rule the reactor presets ship with: once nearly every cell of the
## charge has converted (char, or cracked plastic) and stayed so for twenty
## minutes, the elements go off and the charge cools. `s` = the design's slug.
static func done_rule(s: String) -> Dictionary:
	return {"id": "elements_off_done", "alias": "Elements off when the charge is done", "enabled": true,
		"triggers": [{"kind": "numeric", "entity_id": "sensor.%s_charge_done" % s, "above": 97.0, "for_seconds": 1200.0}],
		"conditions": [], "actions": [{"kind": "scene_node", "command": "turn_off"}]}


## The design's automations as Home Assistant YAML (automations.yaml).
static func ha_yaml(d: Dictionary, autos: Array) -> String:
	var s := design_slug(d)
	var lines: Array = ["# %s: the TC Process Lab's automations" % str((d.get("spec", {}) as Dictionary).get("name", "TC design")),
		"# Entities: sensor.%s_*, switch.%s_*, number.%s_*" % [s, s, s]]
	for a in autos:
		if not (a is Dictionary):
			continue
		var au: Dictionary = a
		lines.append("- id: \"%s_%s\"" % [s, slug(str(au.get("id", au.get("alias", "rule"))))])
		lines.append("  alias: \"%s\"" % str(au.get("alias", "Automation")).replace("\"", "'"))
		lines.append("  mode: single")
		lines.append("  triggers:")
		for t in au.get("triggers", []):
			lines.append_array(_yaml_trigger(t as Dictionary))
		var conds: Array = au.get("conditions", [])
		if not conds.is_empty():
			lines.append("  conditions:")
			for c in conds:
				lines.append_array(_yaml_condition(c as Dictionary))
		lines.append("  actions:")
		for ac in au.get("actions", []):
			lines.append_array(_yaml_action(ac as Dictionary, s))
	return "\n".join(lines) + "\n"


static func _hhmm(h: float) -> String:
	var m := int(round(fposmod(h, 24.0) * 60.0))
	return "%02d:%02d:00" % [(m / 60) % 24, m % 60]


static func _yaml_trigger(t: Dictionary) -> Array:
	match str(t.get("kind", "time")):
		"numeric":
			var o := ["    - trigger: numeric_state", "      entity_id: %s" % t.get("entity_id", "")]
			if t.get("above", null) != null:
				o.append("      above: %s" % _fmt(float(t["above"])))
			if t.get("below", null) != null:
				o.append("      below: %s" % _fmt(float(t["below"])))
			if float(t.get("for_seconds", 0.0)) > 0.0:
				o.append("      for: {seconds: %d}" % int(float(t["for_seconds"])))
			return o
		"state":
			return ["    - trigger: state", "      entity_id: %s" % t.get("entity_id", ""), "      to: \"%s\"" % t.get("to_state", "on")]
		"sun":
			return ["    - trigger: sun", "      event: %s" % t.get("event", "sunset")]
		_:
			return ["    - trigger: time", "      at: \"%s\"" % _hhmm(float(t.get("at_hour", 12.0)))]


static func _yaml_condition(c: Dictionary) -> Array:
	match str(c.get("kind", "time")):
		"numeric":
			var o := ["    - condition: numeric_state", "      entity_id: %s" % c.get("entity_id", "")]
			if c.get("above", null) != null:
				o.append("      above: %s" % _fmt(float(c["above"])))
			if c.get("below", null) != null:
				o.append("      below: %s" % _fmt(float(c["below"])))
			return o
		"state":
			return ["    - condition: state", "      entity_id: %s" % c.get("entity_id", ""), "      state: %s" % [JSON.stringify(c.get("states", ["on"]))]]
		"sun":
			return ["    - condition: state", "      entity_id: sun.sun", "      state: %s" % c.get("state", "above_horizon")]
		_:
			return ["    - condition: time", "      after: \"%s\"" % _hhmm(float(c.get("after_hour", 0.0))),
				"      before: \"%s\"" % _hhmm(float(c.get("before_hour", 24.0)))]


static func _yaml_action(a: Dictionary, s: String) -> Array:
	match str(a.get("kind", "scene_node")):
		"delay":
			return ["    - delay: {seconds: %d}" % int(float(a.get("delay_seconds", 0.0)))]
		"set_value":
			var eid := str(a.get("entity_id", ""))
			var dom := eid.get_slice(".", 0)
			return ["    - action: %s.set_value" % (dom if dom in ["number", "input_number"] else "number"),
				"      target: {entity_id: %s}" % eid, "      data: {value: %s}" % _fmt(float(a.get("value", 0.0)))]
		_:
			var tgt := str(a.get("target", ""))
			if tgt == "":
				tgt = "switch.%s_heaters" % s
			return ["    - action: switch.%s" % str(a.get("command", "turn_on")), "      target: {entity_id: %s}" % tgt]
