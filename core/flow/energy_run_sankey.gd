class_name EnergyRunSankey
extends RefCounted

## "Where the energy went" for a baked run (plans/FLOW_VIZ_PLAN.md Part C):
## the run's energy series split into what the sun offered, what the panels
## took, what went straight to the loads, into the battery and back out, the
## battery's losses, and what was never used. Pure: the challenge debrief, the
## tutorial cards and the selftest read the same numbers.
##
##   flows = flows_from_slices(solar_kw, aux_kw, load_kw, soc_kwh, step_h,
##           potential_kwh, charge_eff)
##   input = loop_input(flows)      # LoopSankeyLayout / LoopSankeyView input
##   view  = make_view(flows, h)    # a LoopSankeyView, or null when empty
##
## Every number is kWh over the run. The split is per step: solar and wind /
## hydro serve the loads first, the rest charges the battery, a shortfall is
## drawn from it. What the battery actually gained is read off the recorded
## state of charge, so its losses are what the series says, not a guess.
## Balance: sun in = not used + panels out; battery in + start charge used =
## battery out + losses + kept.

const KEY := "energy"
const MIN_KWH := 1e-4
const MIN_BOUNDARY_SHARE := 0.03


static func flows_from_slices(solar: PackedFloat32Array, aux: PackedFloat32Array,
		load: PackedFloat32Array, soc: PackedFloat32Array, step_h: float,
		potential_kwh: float = -1.0, charge_eff: float = 0.95) -> Dictionary:
	var n := mini(mini(solar.size(), load.size()), soc.size())
	var f := {"potential": 0.0, "solar": 0.0, "aux": 0.0, "load": 0.0,
		"solar_to_load": 0.0, "aux_to_load": 0.0, "solar_to_batt": 0.0, "aux_to_batt": 0.0,
		"batt_to_load": 0.0, "batt_loss": 0.0, "spilled": 0.0, "not_used": 0.0,
		"from_store": 0.0, "kept": 0.0, "hours": maxf(float(n) * step_h, 0.0)}
	if n == 0 or step_h <= 0.0:
		return f
	var into := 0.0
	var out := 0.0
	for i in n:
		var s := maxf(float(solar[i]), 0.0) * step_h
		var a := maxf(float(aux[i]) if i < aux.size() else 0.0, 0.0) * step_h
		var l := maxf(float(load[i]), 0.0) * step_h
		f["solar"] += s
		f["aux"] += a
		f["load"] += l
		var sd := minf(s, l)
		var ad := minf(a, l - sd)
		f["solar_to_load"] += sd
		f["aux_to_load"] += ad
		var s_left := s - sd
		var a_left := a - ad
		var deficit := l - sd - ad
		# What the battery took this step: the recorded rise, re-grossed by the
		# charging efficiency; what it could not take spilled.
		var d_soc := 0.0
		if i + 1 < soc.size():
			d_soc = float(soc[i + 1]) - float(soc[i])
		if s_left + a_left > 0.0:
			var gross := minf(s_left + a_left, maxf(d_soc, 0.0) / maxf(charge_eff, 0.01))
			if d_soc <= 0.0:
				gross = 0.0
			var share := s_left / (s_left + a_left)
			f["solar_to_batt"] += gross * share
			f["aux_to_batt"] += gross * (1.0 - share)
			f["spilled"] += s_left + a_left - gross
			into += gross
		if deficit > 0.0:
			f["batt_to_load"] += deficit
			out += deficit
	var d_total := float(soc[n - 1]) - float(soc[0])
	if n < soc.size():
		d_total = float(soc[n]) - float(soc[0])
	# Battery balance: into + start charge used = out + loss + kept.
	if d_total >= 0.0:
		f["kept"] = d_total
	else:
		f["from_store"] = -d_total
	f["batt_loss"] = maxf(into + float(f["from_store"]) - out - float(f["kept"]), 0.0)
	if into + float(f["from_store"]) < out + float(f["kept"]):
		# The battery gave more than the series shows going in (rounding, or a
		# load the recorder clipped): count it as stored charge used.
		f["from_store"] = float(f["from_store"]) + out + float(f["kept"]) - into
	var pot := float(f["solar"]) if potential_kwh < 0.0 else maxf(potential_kwh, float(f["solar"]))
	f["potential"] = pot
	f["not_used"] = maxf(pot - float(f["solar"]), 0.0) + float(f["spilled"])
	return f


## From a live EnergyTimeline over [t0, t1].
static func flows_from_timeline(tl: EnergyTimeline, t0: float, t1: float,
		potential_kwh: float = -1.0) -> Dictionary:
	if tl == null or tl.is_empty() or t1 <= t0:
		return {}
	var s := tl.channel_slice("solar_kw", t0, t1)
	var a := tl.channel_slice("aux_kw", t0, t1)
	var l := tl.channel_slice("load_kw", t0, t1)
	var c := tl.channel_slice("soc_kwh", t0, t1)
	return flows_from_slices(s["values"], a["values"], l["values"], c["values"],
		float(s["step"]), potential_kwh, tl.charge_eff)


## Nodes: the panels, wind & hydro (when any), the battery, the loads.
## Sunlight enters the panels from above; what was not used, the battery's
## losses and the charge kept leave below.
static func loop_input(f: Dictionary) -> Dictionary:
	if f.is_empty() or float(f.get("potential", 0.0)) + float(f.get("aux", 0.0)) < MIN_KWH:
		return {}
	var edges: Array = []
	var touched := {}
	var add := func(a: String, b: String, v: float) -> void:
		if v < MIN_KWH:
			return
		edges.append({"id": a + ">" + b, "a": a, "b": b, "key": KEY, "value": v, "conn_ids": []})
		touched[a] = true
		touched[b] = true
	add.call("panels", "loads", float(f.get("solar_to_load", 0.0)))
	add.call("panels", "battery", float(f.get("solar_to_batt", 0.0)))
	add.call("aux", "loads", float(f.get("aux_to_load", 0.0)))
	add.call("aux", "battery", float(f.get("aux_to_batt", 0.0)))
	add.call("battery", "loads", float(f.get("batt_to_load", 0.0)))
	var bin: Array = []
	var bout: Array = []
	# Boundary flows too small to see (under 3 % of the biggest) are left out
	# of the picture: their labels only crowd it. The summary still says them.
	var big := maxf(maxf(float(f.get("potential", 0.0)), float(f.get("aux", 0.0))), float(f.get("load", 0.0)))
	var bnd := func(arr: Array, node: String, v: float, label: String) -> void:
		if v < MIN_KWH or v < big * MIN_BOUNDARY_SHARE:
			return
		arr.append({"node": node, "key": KEY, "value": v, "label": label})
		touched[node] = true
	bnd.call(bin, "panels", float(f.get("potential", 0.0)), "sun")
	bnd.call(bin, "aux", float(f.get("aux", 0.0)), "flow")
	bnd.call(bin, "battery", float(f.get("from_store", 0.0)), "stored")
	bnd.call(bout, "panels", float(f.get("not_used", 0.0)), "not used")
	bnd.call(bout, "battery", float(f.get("batt_loss", 0.0)), "losses")
	bnd.call(bout, "battery", float(f.get("kept", 0.0)), "kept")
	bnd.call(bout, "loads", float(f.get("load", 0.0)), "did work")
	var names := {"panels": "Solar panels", "aux": "Wind & hydro", "battery": "Battery",
		"loads": "Loads"}
	var nodes: Array = []
	var labels := {}
	for id in ["panels", "aux", "battery", "loads"]:
		if touched.has(id):
			labels[id] = names[id]
			nodes.append({"id": id, "label": names[id]})
	return {"nodes": nodes, "edges": edges, "bin": bin, "bout": bout, "labels": labels,
		"types": {}, "keys": [KEY],
		"opts": {"thickness": 30.0, "layer_gap": 60.0, "node_h": 26.0, "min_node_w": 130.0, "node_gap": 120.0}}


## One line: "of 12.4 kWh of sun, 7.1 kWh did work, 3.2 kWh was not used".
static func summary(f: Dictionary) -> String:
	if f.is_empty():
		return ""
	var pot := float(f.get("potential", 0.0)) + float(f.get("aux", 0.0))
	var parts: Array = ["%s did work" % kwh(float(f.get("load", 0.0)))]
	if float(f.get("not_used", 0.0)) >= 0.05:
		parts.append("%s was not used" % kwh(float(f.get("not_used", 0.0))))
	if float(f.get("kept", 0.0)) >= 0.05:
		parts.append("%s was kept in the battery" % kwh(float(f.get("kept", 0.0))))
	return "Of %s on offer, %s." % [kwh(pot), ", ".join(parts)]


## Energy in words, scaled: "640 Wh", "12.4 kWh".
static func kwh(v: float) -> String:
	return UiText.num(v * 1000.0, "Wh")


## A LoopSankeyView of the run, or null when there is nothing to draw.
static func make_view(f: Dictionary, height: float = 220.0) -> Control:
	var inp := loop_input(f)
	if inp.is_empty():
		return null
	var lv: Control = (load("res://scenes/ui/loop_sankey_view.gd") as GDScript).new()
	lv.name = "EnergySankey"
	lv.custom_minimum_size = Vector2(0.0, height)
	lv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lv.call("set_input", inp,
		func(_key: String, v: float) -> String: return kwh(v),
		func(_key: String) -> Color: return GraphTheme.channel("power"),
		func(_key: String) -> String: return "Energy")
	return lv
