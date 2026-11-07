class_name TcProcSummary
extends RefCounted

## A finished TC Process Lab run as a batch recipe for the world's graph
## (Phase 7 of plans/TC_PROCESS_LAB_PLAN.md; the user's "lab only, the world
## uses a summary"). The detailed model runs only in the designer; a placed
## reactor's graph node runs this ProcessRecipe through the flow engine's
## existing scrub-safe batch path (`_process_processor_batch`), so nothing in
## the engine changes:
##   input    the charge, frontloaded (biomass, plastic, water)
##   watts    the run's mean electric draw over the batch
##   outputs  in the node's own port order (a wire on res_out_2 stays on
##            the woodgas), then any new kinds appended:
##              biochar       end of batch (kg)
##              hot_water     the cooling water, through the batch (L)
##              woodgas       Nm³ of dry gas, over the window it came out
##              wood_vinegar  water + acids collected (L), over its window
##              tar           tar / oil / wax collected (kg), over its window
##   steps    the phase changes the run reported (informational, no chores)
##   gas      `gas_lhv_mj_nm3` + `gas_composition` (dry mole fractions),
##            which the Woodgas DC Generator reads instead of its flat
##            1000 Wh/m³ when the gas is wired to it
##
## `fit` is pure over a sim parked at the end of its run plus the panel's
## history samples and the run's events.

const GAS_EXCLUDE := ["H2O", "tar", "acetic", "ethanol", "oil", "wax"]
const VINEGAR := ["H2O", "acetic", "ethanol"]
const HEAVY := ["tar", "oil", "wax"]
const NM3_PER_MOL := 0.022414
const WINDOW_LO := 0.05            # an output's window: 5 % … 95 % of its total
const WINDOW_HI := 0.95
## The producer gas the generator preset's 1000 Wh/m³ was set for (MJ/Nm³):
## air-blown gasifier gas runs 4–6 (Reed & Das 1988).
const REF_LHV_MJ_NM3 := 5.0


static func feed_kind(proc: Dictionary) -> String:
	var feed := str((proc.get("charge", {}) as Dictionary).get("feed", "wood_chips"))
	match feed:
		"pe_pellets", "pp_pellets":
			return "plastic_waste"
		"water", "wash":
			return "water"
	return "biomass"


## The recipe. sim: parked at the end of the run. history: the panel's
## samples [{t_h, gas_dry, cond, e_kwh, ...}]. events: the run's log.
## base_inputs / base_outputs: the bound node's ports (kinds in order).
static func fit(d: Dictionary, proc: Dictionary, sim: TcProcSim, history: Array, events: Array,
		base_inputs: Array = [], base_outputs: Array = []) -> Dictionary:
	var dur := float(proc.get("duration_h", 8.0))
	var t_done := _event_h(events, "done")
	# The batch ends when the gas has tailed off (or at the event that says
	# the charge is char), never past the run.
	var gas_win := _window(history, "gas_dry", true)
	var t_end := dur
	if t_done < INF:
		t_end = maxf(t_done, float(gas_win[1]) if gas_win[1] < INF else 0.0) + 0.25
	elif gas_win[1] < INF:
		t_end = float(gas_win[1]) + 0.25
	var batch_h := clampf(t_end, 0.25, dur)
	var kwh := _at(history, "e_kwh", batch_h)
	var watts := kwh * 1000.0 / maxf(batch_h, 1e-6)
	# What came out.
	var dry := {}
	var gas_mol := 0.0
	for s in TcProcSim.NS:
		var sp := str(TcProcSim.SP[s])
		var m := sim.product_mol[s] + sim.vented_mol[s]
		if sp in GAS_EXCLUDE or m <= 0.0:
			continue
		dry[sp] = m
		gas_mol += m
	var comp := {}
	for k in dry.keys():
		comp[k] = float(dry[k]) / maxf(gas_mol, 1e-12)
	var lhv := TcThermo.lhv_mj_per_nm3(dry) if gas_mol > 0.0 else 0.0
	var vinegar_kg := 0.0
	var heavy_kg := 0.0
	for s2 in TcProcSim.NS:
		var sp2 := str(TcProcSim.SP[s2])
		var held := 0.0
		for i in sim.n_cv:
			if str(sim.net["cvs"][i]["role"]) != "vessel":
				held += (sim.liq[i] as PackedFloat64Array)[s2]
		var kg := (sim.drained_mol[s2] + held) * TcSpecies.molar_mass_kg(sp2)
		if sp2 in VINEGAR:
			vinegar_kg += kg
		elif sp2 in HEAVY:
			heavy_kg += kg
	var char_kg := 0.0
	if sim.bed != null and not sim.bed.is_empty():
		char_kg = float(sim.bed.totals()["char_kg"])
	var cool_lpm := float((proc.get("cooling", {}) as Dictionary).get("lpm", 2.0))
	var cond_win := _window(history, "cond", false)
	var mass := float((proc.get("charge", {}) as Dictionary).get("mass_kg", 10.0))
	var made := {
		"biochar": {"qty": char_kg, "mode": "end_batch", "unit": "kg"},
		"hot_water": {"qty": cool_lpm * 60.0 * batch_h if not sim.cool_lpm.is_empty() else 0.0, "mode": "continuous", "unit": "L"},
		"woodgas": {"qty": gas_mol * NM3_PER_MOL, "unit": "m³", "window": gas_win,
			"lhv_mj_nm3": lhv, "composition": comp},
		"wood_vinegar": {"qty": vinegar_kg / 1.0, "unit": "L", "window": cond_win},
		"tar": {"qty": heavy_kg, "unit": "kg", "window": cond_win},
	}
	var outputs: Array = []
	var seen := {}
	for bo in base_outputs:
		var k := ResourceKinds.normalize_kind(str((bo as Dictionary).get("kind", "")))
		if made.has(k) and not seen.has(k):
			outputs.append(_io(k, made[k], batch_h))
			seen[k] = true
		else:
			# A port the run makes nothing for keeps its place (and its wires).
			outputs.append({"kind": k, "qty": 0.0, "mode": "end_batch", "unit": str((bo as Dictionary).get("unit", ""))})
			seen[k] = true
	for k2 in ["biochar", "hot_water", "woodgas", "wood_vinegar", "tar"]:
		if not seen.has(k2) and float((made[k2] as Dictionary)["qty"]) > 1e-6:
			outputs.append(_io(k2, made[k2], batch_h))
	var fk := feed_kind(proc)
	var inputs: Array = []
	var placed := false
	for bi in base_inputs:
		var k3 := ResourceKinds.normalize_kind(str((bi as Dictionary).get("kind", "")))
		if k3 == fk and not placed:
			inputs.append({"kind": fk, "qty": mass, "mode": "frontloaded", "unit": "kg"})
			placed = true
		else:
			inputs.append({"kind": k3, "qty": 0.0, "mode": "frontloaded", "unit": str((bi as Dictionary).get("unit", ""))})
	if not placed:
		inputs.push_front({"kind": fk, "qty": mass, "mode": "frontloaded", "unit": "kg"})
	var steps: Array = []
	for e in [["drying", "Drying starts"], ["pyrolysis", "Pyrolysis begins"], ["dry", "The charge is dry"], ["done", "The charge is char"]]:
		var th := _event_h(events, str(e[0]))
		if th < INF and th <= batch_h:
			steps.append({"id": str(e[0]), "label": str(e[1]), "at_frac": th / batch_h, "chore_hours": 0.0})
	var name := str((d.get("spec", {}) as Dictionary).get("name", "TC design"))
	var hw := ""
	var nh := sim.heater_parts.size()
	if nh > 0:
		hw = ", %d × %d W" % [nh, int(round(float(TcProcSpec.heater(proc, str(sim.heater_parts[0]))["w"])))]
	var feed_label := str((TcProcSpec.FEEDS.get(str((proc.get("charge", {}) as Dictionary).get("feed", "")), {}) as Dictionary).get("label", "charge")).to_lower()
	var summary := {"batch_h": batch_h, "kwh": kwh, "watts": watts, "char_kg": char_kg,
		"gas_nm3": gas_mol * NM3_PER_MOL, "gas_lhv_mj_nm3": lhv, "gas_composition": comp,
		"vinegar_l": vinegar_kg, "tar_kg": heavy_kg, "feed_kg": mass}
	var key := "%s|%.3f|%.3f|%.3f|%.3f" % [name, batch_h, char_kg, gas_mol, vinegar_kg]
	var r := {
		"id": "tc_%s_%d" % [TcProcControl.slug(name), absi(hash(key)) % 1000000],
		"label": "%s: a lab run (%s kg %s%s)" % [name, _fmt(mass), feed_label, hw],
		"compatible_roles": [],
		"batch_time_hrs": batch_h,
		"failure_mode": "pause_and_resume",
		"chore_hours": 0.0,
		"require_confirm_start": false,
		"inputs": inputs,
		"outputs": outputs,
		"steps": steps,
		"note": "From a TC Process Lab run: %.1f h, %.2f kWh, %.2f kg char, %.2f Nm³ gas at %.1f MJ/Nm³, %.2f L wood vinegar, %.2f kg tar." % [
			batch_h, kwh, char_kg, gas_mol * NM3_PER_MOL, lhv, vinegar_kg, heavy_kg],
		"tc_summary": summary,
	}
	return ProcessRecipe.normalize(r).merged({"tc_summary": summary, "watts": watts, "gas_lhv_mj_nm3": lhv,
		"gas_composition": comp})


static func _io(kind: String, m: Dictionary, batch_h: float) -> Dictionary:
	var io := {"kind": kind, "qty": float(m["qty"]), "unit": str(m.get("unit", ""))}
	if m.has("window"):
		var w: Array = m["window"]
		if w[0] < INF and w[1] < INF and float(w[1]) > float(w[0]):
			io["mode"] = "delayed"
			io["delay_hrs"] = clampf(float(w[0]), 0.0, batch_h)
			io["duration_hrs"] = maxf(minf(float(w[1]), batch_h) - float(io["delay_hrs"]), 0.05)
		else:
			io["mode"] = "end_batch"
	else:
		io["mode"] = str(m.get("mode", "end_batch"))
	if m.has("lhv_mj_nm3"):
		io["lhv_mj_nm3"] = m["lhv_mj_nm3"]
		io["composition"] = m["composition"]
	return io


static func _fmt(v: float) -> String:
	return str(int(round(v))) if absf(v - round(v)) < 0.05 else "%.1f" % v


static func _event_h(events: Array, id: String) -> float:
	for e in events:
		if str((e as Dictionary).get("id", "")) == id:
			return float(e["t_s"]) / 3600.0
	return INF


## A history key at t_h (linear between samples).
static func _at(history: Array, key: String, t_h: float) -> float:
	var prev: Dictionary = {}
	for h in history:
		var t := float(h["t_h"])
		if t >= t_h:
			if prev.is_empty():
				return float(h.get(key, 0.0))
			var t0 := float(prev["t_h"])
			var u := (t_h - t0) / maxf(t - t0, 1e-9)
			return lerpf(float(prev.get(key, 0.0)), float(h.get(key, 0.0)), u)
		prev = h
	return float(prev.get(key, 0.0)) if not prev.is_empty() else 0.0


## [start, end] hours of a quantity: a RATE (above 5 % of its peak) or a
## running TOTAL (between 5 % and 95 % of its final value). INF when none.
static func _window(history: Array, key: String, is_rate: bool) -> Array:
	if history.is_empty():
		return [INF, INF]
	if is_rate:
		var peak := 0.0
		for h in history:
			peak = maxf(peak, float(h.get(key, 0.0)))
		if peak <= 0.0:
			return [INF, INF]
		var a := INF
		var b := INF
		for h2 in history:
			if float(h2.get(key, 0.0)) >= peak * WINDOW_LO:
				if a == INF:
					a = float(h2["t_h"])
				b = float(h2["t_h"])
		return [a, b]
	var last := float((history[-1] as Dictionary).get(key, 0.0))
	if last <= 0.0:
		return [INF, INF]
	var s := INF
	var e := INF
	for h3 in history:
		var v := float(h3.get(key, 0.0))
		if s == INF and v >= last * WINDOW_LO:
			s = float(h3["t_h"])
		if e == INF and v >= last * WINDOW_HI:
			e = float(h3["t_h"])
	return [s, e]


## Write the recipe onto a graph processor's specs (its ports keep their
## order, the recipe's watts and gas LHV ride along).
static func apply_to_specs(specs: Dictionary, recipe: Dictionary) -> void:
	ProcessRecipe.apply_to_specs(specs, recipe)
	specs["watts"] = float(recipe.get("watts", specs.get("watts", 0.0)))
	specs["gas_lhv_mj_nm3"] = float(recipe.get("gas_lhv_mj_nm3", 0.0))
	specs["gas_composition"] = (recipe.get("gas_composition", {}) as Dictionary).duplicate()
	specs["tc_summary"] = (recipe.get("tc_summary", {}) as Dictionary).duplicate()


## The design's automations the world can run as they are: time / sun
## triggers and conditions, switching the whole machine. The rest read lab
## sensors and stay in the lab. Returns {world: [specs], lab_only: [alias]}.
static func world_automations(autos: Array) -> Dictionary:
	var world: Array = []
	var lab: Array = []
	for a in autos:
		if not (a is Dictionary):
			continue
		var au: Dictionary = a
		var ok := not (au.get("triggers", []) as Array).is_empty()
		for t in au.get("triggers", []):
			if str((t as Dictionary).get("kind", "")) not in ["time", "sun"]:
				ok = false
		for c in au.get("conditions", []):
			if str((c as Dictionary).get("kind", "")) not in ["time", "sun"]:
				ok = false
		for ac in au.get("actions", []):
			var k := str((ac as Dictionary).get("kind", ""))
			if k == "set_value" or (k == "scene_node" and str((ac as Dictionary).get("target", "")) != ""):
				ok = false
		if ok:
			var w := au.duplicate(true)
			w["id"] = "tc_%s" % str(au.get("id", au.get("alias", "rule")))
			world.append(w)
		else:
			lab.append(str(au.get("alias", "Automation")))
	return {"world": world, "lab_only": lab}
