class_name DesignGap
extends RefCounted

## The gap node (resource composition plan Phase 8): a placeholder for a
## machine nobody has built yet. It does what the site needs done, as far as
## conservation allows, and meters what that took, so its numbers become a
## design brief. Pure: the flow engine gathers what is on offer and what the
## outputs can take, `step` decides, the engine moves it.
##
## Inputs: it takes everything offered on each wired input (an input's
##   listed rate, when above 0, caps it).
## Outputs: each delivers its listed rate (0 = as much as the inputs allow),
##   all scaled down together until no element leaves in greater quantity than
##   it came in. An element that is a TRACE of what is asked (under
##   TRACE_SHARE of its mass: the calcium in reclaimed water) does not scale
##   the outputs; its lack is shortfall like any other.
##   What the outputs would have needed beyond the inputs is the SHORTFALL
##   ("needs an extra input"): out ≤ in + shortfall for every element.
## Residue: what came in and did not leave goes to an output marked
##   `residue` (as much of its kind as the leftover elements make), and the
##   rest is reported as left on site or to the air ("0.4 kg/day of salts
##   must leave somewhere").
## Energy: a target in kWh per kg processed (`gap_kwh_per_kg` ≥ 0) is drawn
##   as watts; with none (−1) it is reported as unknown, never drawn.

const ROLE := "design_gap"
## Elements a brief talks about (water is H and O; it is reported apart).
const TRACK := ["C", "N", "P", "K"]
## An element below this share of the asked outputs' mass is a trace.
const TRACE_SHARE := 0.005


## A fresh gap node's specs. `ins` / `outs`: [{kind, rate}] (qty per hour;
## 0 = "everything offered" / "as much as possible").
static func make_specs(name: String, ins: Array, outs: Array, extra: Dictionary = {}) -> Dictionary:
	var sp := {"name": name, "role": ROLE, "inputs": [], "outputs": [], "watts": 0.0, "cost": 0.0,
		"energy_source": "", "efficiency": 1.0, "gap_kwh_per_kg": -1.0, "requested_state": "on"}
	for i in ins:
		var d: Dictionary = i
		(sp["inputs"] as Array).append({"kind": str(d["kind"]), "rate": float(d.get("rate", 0.0)),
			"unit": _unit(str(d["kind"])) + "/h"})
	for o in outs:
		var d2: Dictionary = o
		var row := {"kind": str(d2["kind"]), "rate": float(d2.get("rate", 0.0)), "unit": _unit(str(d2["kind"])) + "/h"}
		if bool(d2.get("residue", false)):
			row["residue"] = true
		(sp["outputs"] as Array).append(row)
	for k in extra.keys():
		sp[k] = extra[k]
	return sp


static func is_gap(specs: Dictionary) -> bool:
	return str(specs.get("role", "")) == ROLE


## One step. avail: [{kind, qty_h (offered, qty/h), cap_h (listed rate, 0 =
## none)}] per input; outs: [{kind, want_h (listed rate, 0 = as much as
## possible), room_h (what its tank can take, qty/h; INF = no limit),
## residue: bool}] per output.
## → {take: [qty/h], give: [qty/h], kg_in, kg_out, el_in, el_out, residue
## (element kg/h left over), short (element kg/h the outputs lacked),
## water_in, water_out (kg/h), power_w (−1 = no target), running: bool}.
static func step(avail: Array, outs: Array, kwh_per_kg: float = -1.0) -> Dictionary:
	var res := {"take": [], "give": [], "kg_in": 0.0, "kg_out": 0.0, "el_in": {}, "el_out": {},
		"residue": {}, "short": {}, "water_in": 0.0, "water_out": 0.0, "power_w": -1.0, "running": false}
	var el_in: Dictionary = {}
	for a in avail:
		var ad: Dictionary = a
		var q := maxf(float(ad.get("qty_h", 0.0)), 0.0)
		var cap := float(ad.get("cap_h", 0.0))
		if cap > 0.0:
			q = minf(q, cap)
		(res["take"] as Array).append(q)
		var kg := q * CompositionCatalog.kg_per_unit(str(ad["kind"]))
		res["kg_in"] = float(res["kg_in"]) + kg
		res["water_in"] = float(res["water_in"]) + kg * CompositionCatalog.water_fraction(str(ad["kind"]))
		_add_elements(el_in, str(ad["kind"]), kg)
	res["el_in"] = el_in
	# The outputs it is asked for (want 0 → as much as possible, sized after).
	var want: Array = []
	var need_el: Dictionary = {}
	var need_kg := 0.0
	for o in outs:
		var od: Dictionary = o
		var w := maxf(float(od.get("want_h", 0.0)), 0.0)
		if bool(od.get("residue", false)):
			w = 0.0
		want.append(w)
		if w > 0.0:
			var kg0 := w * CompositionCatalog.kg_per_unit(str(od["kind"]))
			need_kg += kg0
			_add_elements(need_el, str(od["kind"]), kg0)
	# One factor for all of them: no (non-trace) element out beyond what came in.
	var f := 1.0
	for e in need_el.keys():
		var need := float(need_el[e])
		if need > 1e-12 and need >= TRACE_SHARE * need_kg:
			f = minf(f, float(el_in.get(e, 0.0)) / need)
	f = clampf(f, 0.0, 1.0)
	for e2 in need_el.keys():
		var lack := float(need_el[e2]) * f - float(el_in.get(e2, 0.0))
		var full_lack := float(need_el[e2]) - float(el_in.get(e2, 0.0))
		# What it delivers beyond the inputs (traces) and what the asked
		# outputs needed beyond them.
		if maxf(lack, full_lack) > 1e-12:
			(res["short"] as Dictionary)[e2] = maxf(lack, full_lack)
	var left := el_in.duplicate()
	var give: Array = []
	for i in outs.size():
		var od2: Dictionary = outs[i]
		var g := float(want[i]) * f
		g = minf(g, float(od2.get("room_h", INF)))
		give.append(maxf(g, 0.0))
		_sub_elements(left, str(od2["kind"]), give[i] * CompositionCatalog.kg_per_unit(str(od2["kind"])))
	# "As much as possible" outputs, then the residue output, from what is left.
	for pass_residue in [false, true]:
		for j in outs.size():
			var od3: Dictionary = outs[j]
			if bool(od3.get("residue", false)) != pass_residue or (float(want[j]) > 0.0 and not pass_residue):
				continue
			var kpu := CompositionCatalog.kg_per_unit(str(od3["kind"]))
			var per: Dictionary = CompositionCatalog.elements_of(str(od3["kind"]))
			var most := INF
			for e3 in per.keys():
				var share := float(per[e3])
				# Traces (the calcium in reclaimed water) do not cap it.
				if share >= TRACE_SHARE:
					most = minf(most, maxf(float(left.get(e3, 0.0)), 0.0) / (share * kpu))
			if most == INF or most <= 0.0:
				continue
			var g2 := minf(most, float(od3.get("room_h", INF)))
			give[j] = float(give[j]) + g2
			_sub_elements(left, str(od3["kind"]), g2 * kpu)
			# A trace it delivers beyond what came in is shortfall.
			for e5 in per.keys():
				if float(left.get(e5, 0.0)) < -1e-12:
					(res["short"] as Dictionary)[e5] = float((res["short"] as Dictionary).get(e5, 0.0)) - float(left[e5])
					left[e5] = 0.0
	res["give"] = give
	var el_out: Dictionary = {}
	for k in outs.size():
		var kg2 := float(give[k]) * CompositionCatalog.kg_per_unit(str((outs[k] as Dictionary)["kind"]))
		res["kg_out"] = float(res["kg_out"]) + kg2
		res["water_out"] = float(res["water_out"]) + kg2 * CompositionCatalog.water_fraction(str((outs[k] as Dictionary)["kind"]))
		_add_elements(el_out, str((outs[k] as Dictionary)["kind"]), kg2)
	res["el_out"] = el_out
	var residue: Dictionary = {}
	for e4 in left.keys():
		if float(left[e4]) > 1e-12:
			residue[e4] = float(left[e4])
	res["residue"] = residue
	res["running"] = float(res["kg_in"]) > 1e-9 or float(res["kg_out"]) > 1e-9
	if kwh_per_kg >= 0.0:
		res["power_w"] = kwh_per_kg * float(res["kg_in"]) * 1000.0
	return res


static func _add_elements(acc: Dictionary, kind: String, kg: float) -> void:
	if kg <= 0.0:
		return
	var per: Dictionary = CompositionCatalog.elements_of(kind)
	for e in per.keys():
		acc[e] = float(acc.get(e, 0.0)) + float(per[e]) * kg


static func _sub_elements(acc: Dictionary, kind: String, kg: float) -> void:
	if kg <= 0.0:
		return
	var per: Dictionary = CompositionCatalog.elements_of(kind)
	for e in per.keys():
		acc[e] = float(acc.get(e, 0.0)) - float(per[e]) * kg


static func _unit(kind: String) -> String:
	return str(ResourceKinds.kind_meta(kind).get("unit", "kg"))
