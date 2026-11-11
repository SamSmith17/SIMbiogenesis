class_name ElementLedger
extends RefCounted

## What a scope of the graph HOLDS and MOVES, by element (resource
## composition plan Phase 2; the CampLedger sibling). Pure over the model:
## tank stocks and the live wire flows the flow engine stamps (`flow_rate`,
## in the kind's unit per hour) turned into kg, water and elements by
## CompositionCatalog.
##
##   stock      everything stored: kg, usable water (clean water kinds),
##              water bound in other stores (urine, food, biomass …), each
##              element, chemical energy (LHV + sensible heat), food energy
##   stores     one row per tank
##   unknown    stores whose kind has no composition (counted apart)
##   boundary   what crosses the scope: `rain` (catchments), `imports`
##              (deliveries, pumps, unlimited supply tanks, import nodes),
##              `in` / `out` across a compound's edge, `exports` (outlet
##              sinks); each a side {kg_h, water_kg_h, elements}
##   nodes      per machine / habitat / plant, what its wires bring and take
##   unaccounted machines, habitats and plant beds whose live flows do not
##              balance an element once their air side is closed
##              (MassBalance.check with the node's air mode and retained
##              elements), worst first
##   air        what the scope gives to and takes from the atmosphere, the
##              implicit boundary: `out` / `in` sides plus `gases` {gas: kg/h,
##              + = given off}
##   dumped     unwired optional outputs (cooling water, backwash): the
##              machine runs and the stream is drained off site
##   leaks      outputs with nowhere to go, full stores still filling
##   water      {used_kg_h, recovered_kg_h, ratio}: ISS-style water recovery
##
## Water recovery (the ECLSS measure, recovered for reuse ÷ water used): a
## node's waste outputs count as USED water by the share of its water intake
## that was clean (a habitat, a kitchen); its clean-water outputs count as
## RECOVERED by the share that came from waste (a still on urine, a filter
## on greywater). A digester passing waste to waste counts as neither, so
## nothing is counted twice down a treatment chain.
##
## Flows are what the engine stamped last tick (rates now, per hour). A
## history window is Phase 4 (from the tank timelines).

const SIDE_KEYS := ["kg_h", "water_kg_h", "elements"]
## An element's imbalance worth reporting: kg/h and share of the larger side.
const UNACCOUNTED_MIN_KG_H := 1e-5
const UNACCOUNTED_MIN_REL := 0.05
const REPORT_ELEMENTS := ["C", "N", "P", "K"]
## A store this full that still takes inflow is spilling.
const FULL_LEVEL := 0.999


static func compute(model: GraphModel, scope_id: String = "root") -> Dictionary:
	var out := {"stock": _empty_stock(), "stores": [], "unknown": [], "nodes": {},
		"boundary": {"rain": _side(), "imports": _side(), "in": _side(), "out": _side(), "exports": _side()},
		"unaccounted": [], "leaks": [], "water": {"used_kg_h": 0.0, "recovered_kg_h": 0.0, "ratio": NAN},
		"air": {"out": _side(), "in": _side(), "gases": {}}, "dumped": _side(),
		"scope_id": scope_id}
	if model == null:
		return out
	var items: Array = GraphNesting.walk_items(model, scope_id)
	var inside: Dictionary = {}
	for it in items:
		inside[str((it as Dictionary).get("id", ""))] = it
	_stocks(items, out)
	# Live rates sit on the model's own connection dicts (flat copies are
	# cached per revision and carry stale telemetry).
	var rate_of: Dictionary = {}
	for c in model.connections:
		var cd: Dictionary = c
		rate_of[str(cd.get("id", ""))] = float(cd.get("flow_rate", 0.0))
	var nodes: Dictionary = out["nodes"]
	var has_mat_in: Dictionary = {}
	var inflow_to: Dictionary = {}
	var wires: Array = []
	for fc in GraphNesting.flat_connections_cached(model):
		var f: Dictionary = fc
		if str(f.get("polarity", "")) != "resource":
			continue
		var kind := str(f.get("resource_type", ""))
		if kind.is_empty() or not CompositionCatalog.is_material(kind):
			continue
		var src := str(f.get("source_item_id", ""))
		var tgt := str(f.get("target_item_id", ""))
		if not inside.has(src) and not inside.has(tgt):
			continue
		if inside.has(tgt):
			has_mat_in[tgt] = true
		var rate := float(rate_of.get(str(f.get("id", "")), 0.0))
		if rate <= 0.0:
			continue
		var emb := CompositionCatalog.embodied(kind, rate)
		if not bool(emb["known"]):
			continue
		wires.append({"src": src, "tgt": tgt, "kind": kind, "emb": emb, "rate": rate})
		if inside.has(tgt):
			inflow_to[tgt] = float(inflow_to.get(tgt, 0.0)) + float(emb["kg"])
	for w in wires:
		var src2 := str(w["src"])
		var tgt2 := str(w["tgt"])
		var emb2: Dictionary = w["emb"]
		var kind2 := str(w["kind"])
		var src_in := inside.has(src2)
		var tgt_in := inside.has(tgt2)
		var b: Dictionary = out["boundary"]
		if src_in and not tgt_in:
			_add(b["out"], emb2)
		elif tgt_in and not src_in:
			_add(b["in"], emb2)
		if src_in:
			var si: Dictionary = inside[src2]
			if _is_rain_source(si):
				_add(b["rain"], emb2)
			elif _is_import_source(si, has_mat_in.has(src2)):
				_add(b["imports"], emb2)
			if _is_node(si):
				_node(nodes, si)["out"].append({"kind": kind2, "emb": emb2, "rate": float(w["rate"])})
		if tgt_in:
			var ti: Dictionary = inside[tgt2]
			if _is_outlet_sink(ti):
				_add(b["exports"], emb2)
			if _is_node(ti):
				_node(nodes, ti)["in"].append({"kind": kind2, "emb": emb2, "rate": float(w["rate"])})
	_finish_nodes(nodes, out)
	_leaks(items, inflow_to, out)
	return out


# --- stocks -------------------------------------------------------------------

static func _empty_stock() -> Dictionary:
	return {"kg": 0.0, "usable_water_kg": 0.0, "bound_water_kg": 0.0, "elements": {},
		"energy_mj": 0.0, "food_mj": 0.0, "bound_by_kind": {}, "unlimited": 0}


static func _stocks(items: Array, out: Dictionary) -> void:
	var st: Dictionary = out["stock"]
	for it in items:
		var d: Dictionary = it
		if str(d.get("type", "")) != "resource" or bool(d.get("is_ghost", false)):
			continue
		var specs: Dictionary = d.get("specs", {})
		var kind := str(specs.get("resource_kind", ""))
		if kind.is_empty() or not CompositionCatalog.is_material(kind):
			continue
		# Infinite supplies and outlet sinks are the site's edge, not its stock.
		if bool(specs.get("unlimited_capacity", false)) or bool(specs.get("outlet_sink", false)) \
				or bool(specs.get("allow_negative", false)):
			st["unlimited"] = int(st["unlimited"]) + 1
			continue
		var qty := ResourceKinds.tank_stock_qty(specs)
		var name := str(specs.get("name", d.get("id", "")))
		var emb := CompositionCatalog.embodied(kind, qty)
		var row := {"id": str(d.get("id", "")), "name": name, "kind": kind, "qty": qty,
			"unit": ResourceKinds.default_unit(kind), "known": bool(emb["known"])}
		if not bool(emb["known"]):
			(out["unknown"] as Array).append(row)
			continue
		row.merge(emb)
		(out["stores"] as Array).append(row)
		st["kg"] = float(st["kg"]) + float(emb["kg"])
		var wkg := float(emb["water_kg"])
		if CompositionCatalog.is_clean_water(kind):
			st["usable_water_kg"] = float(st["usable_water_kg"]) + wkg
		elif wkg > 0.0:
			st["bound_water_kg"] = float(st["bound_water_kg"]) + wkg
			var bk: Dictionary = st["bound_by_kind"]
			bk[kind] = float(bk.get(kind, 0.0)) + wkg
		st["energy_mj"] = float(st["energy_mj"]) + float(emb["energy_mj"])
		st["food_mj"] = float(st["food_mj"]) + float(emb["kg"]) * CompositionCatalog.food_mj_per_kg(kind)
		_add_elements(st["elements"], emb["elements"])


# --- flows --------------------------------------------------------------------

static func _side() -> Dictionary:
	return {"kg_h": 0.0, "water_kg_h": 0.0, "elements": {}}


static func _add(side: Dictionary, emb: Dictionary) -> void:
	side["kg_h"] = float(side["kg_h"]) + float(emb["kg"])
	side["water_kg_h"] = float(side["water_kg_h"]) + float(emb["water_kg"])
	_add_elements(side["elements"], emb["elements"])


static func _add_elements(into: Dictionary, el: Dictionary) -> void:
	for e in el.keys():
		into[e] = float(into.get(e, 0.0)) + float(el[e])


static func _is_node(item: Dictionary) -> bool:
	var ty := str(item.get("type", ""))
	return (ty == "processor" or ty == "plant") and not bool(item.get("is_ghost", false))


static func _is_rain_source(item: Dictionary) -> bool:
	return str(item.get("type", "")) == "catchment"


static func _is_outlet_sink(item: Dictionary) -> bool:
	return str(item.get("type", "")) == "resource" and bool((item.get("specs", {}) as Dictionary).get("outlet_sink", false))


## Material comes in from outside the site here: an import node, an
## unlimited supply tank, or a machine with material out and none in (a
## pump, a delivery run).
static func _is_import_source(item: Dictionary, has_material_in: bool) -> bool:
	var specs: Dictionary = item.get("specs", {})
	if bool(specs.get("counts_as_import", false)):
		return true
	var ty := str(item.get("type", ""))
	if ty == "resource":
		return bool(specs.get("unlimited_capacity", false)) or bool(specs.get("allow_negative", false))
	if ty == "processor" and str(specs.get("role", "")) != "habitat":
		return not has_material_in
	return false


static func _node(nodes: Dictionary, item: Dictionary) -> Dictionary:
	var id := str(item.get("id", ""))
	if not nodes.has(id):
		var specs: Dictionary = item.get("specs", {})
		nodes[id] = {"id": id, "name": str(specs.get("name", id)), "type": str(item.get("type", "")),
			"habitat": str(specs.get("role", "")) == "habitat", "in": [], "out": [], "item": item}
	return nodes[id]


static func _finish_nodes(nodes: Dictionary, out: Dictionary) -> void:
	var used := 0.0
	var recovered := 0.0
	var unacc: Array = []
	for id in nodes.keys():
		var n: Dictionary = nodes[id]
		var side_in := _side()
		var side_out := _side()
		var w_clean_in := 0.0
		var w_waste_in := 0.0
		for e in n["in"]:
			_add(side_in, e["emb"])
			var wk := float((e["emb"] as Dictionary)["water_kg"])
			if CompositionCatalog.is_waste(str(e["kind"])):
				w_waste_in += wk
			else:
				w_clean_in += wk
		var w_waste_out := 0.0
		var w_clean_out := 0.0
		for e2 in n["out"]:
			_add(side_out, e2["emb"])
			var wk2 := float((e2["emb"] as Dictionary)["water_kg"])
			if CompositionCatalog.is_waste(str(e2["kind"])):
				w_waste_out += wk2
			elif CompositionCatalog.is_clean_water(str(e2["kind"])):
				w_clean_out += wk2
		var w_in := w_clean_in + w_waste_in
		var clean_share := w_clean_in / w_in if w_in > 0.0 else 1.0
		var waste_share := w_waste_in / w_in if w_in > 0.0 else 0.0
		used += w_waste_out * clean_share
		recovered += w_clean_out * waste_share
		n["in_side"] = side_in
		n["out_side"] = side_out
		var judged := _judge(n, out)
		n["in"] = (n["in"] as Array).size()
		n["out"] = (n["out"] as Array).size()
		n.erase("item")
		if not judged.is_empty():
			unacc.append(judged)
	unacc.sort_custom(func(a, b) -> bool: return float(a["score"]) > float(b["score"]))
	out["unaccounted"] = unacc
	out["water"] = {"used_kg_h": used, "recovered_kg_h": recovered,
		"ratio": clampf(recovered / used, 0.0, 1.0) if used > 1e-9 else NAN}


## One node's live balance with its air side closed. Adds its air gases and
## dumped outputs to the scope's sides; returns an unaccounted row or {}.
static func _judge(n: Dictionary, out: Dictionary) -> Dictionary:
	var item: Dictionary = n.get("item", {})
	var specs: Dictionary = item.get("specs", {})
	var ins := _io_list(n["in"])
	var outs := _io_list(n["out"])
	# Optional outputs left unwired are drained off site at the rate the
	# machine is running (the share of its listed input it is drawing now).
	var dumped: Array = []
	var unwired: Variant = specs.get("output_unconnected_kinds", [])
	if unwired is Array and not (unwired as Array).is_empty() and str(n["type"]) == "processor":
		var scale := _run_share(specs.get("inputs", []), n["in"])
		if scale > 0.0:
			for o in specs.get("outputs", []):
				var od: Dictionary = o
				var ok := str(od.get("kind", ""))
				if (unwired as Array).has(ok) and bool(od.get("optional", false)) and CompositionCatalog.is_material(ok):
					dumped.append({"kind": ok, "rate": float(od.get("rate", 0.0)) * scale})
	for dd in dumped:
		var emb := CompositionCatalog.embodied(str(dd["kind"]), float(dd["rate"]))
		if bool(emb["known"]):
			_add(out["dumped"], emb)
	if ins.is_empty() and outs.is_empty():
		return {}
	var air: Variant = MassBalance.air_for(item)
	var retain: Array = MassBalance.retain_for(item)
	var mb := MassBalance.check(ins, outs + dumped, [], [], UNACCOUNTED_MIN_REL, air, {"retain": retain})
	var air_side: Dictionary = out["air"]
	var gases: Dictionary = mb.get("air", {})
	for g in gases.keys():
		var kg := float(gases[g])
		(air_side["gases"] as Dictionary)[g] = float((air_side["gases"] as Dictionary).get(g, 0.0)) + kg
		var ge := CompositionCatalog.component_elements(str(g))
		var emb2 := {"kg": absf(kg), "water_kg": absf(kg) if str(g) == "H2O" else 0.0, "elements": {}}
		for e in ge.keys():
			(emb2["elements"] as Dictionary)[e] = absf(kg) * float(ge[e])
		_add(air_side["out"] if kg > 0.0 else air_side["in"], emb2)
	n["verdict"] = str(mb["verdict"])
	n["air"] = gases
	# A node with nothing coming in or nothing going out is a source or a
	# sink by design (a pump, a burner); only a two-sided node is judged.
	if ins.is_empty() or (outs.is_empty() and dumped.is_empty() and gases.is_empty()):
		return {}
	var deltas: Dictionary = {}
	var worst := ""
	var worst_rel := 0.0
	for e2 in (mb["loses"] as Array) + (mb["creates"] as Array):
		var d := float((mb["delta"] as Dictionary).get(e2, 0.0))
		if absf(d) < UNACCOUNTED_MIN_KG_H:
			continue
		deltas[e2] = d
		var r := float((mb["rel"] as Dictionary).get(e2, 0.0))
		if absf(r) > absf(worst_rel):
			worst = str(e2)
			worst_rel = r
	if deltas.is_empty():
		return {}
	return {"id": str(n["id"]), "name": str(n["name"]), "deltas": deltas, "worst": worst,
		"worst_kg_h": float(deltas.get(worst, 0.0)), "worst_rel": worst_rel, "water_kg_h": 0.0,
		"score": absf(worst_rel)}


## Wire entries summed per kind into MassBalance io dicts.
static func _io_list(entries: Array) -> Array:
	var by: Dictionary = {}
	for e in entries:
		var k := str(e["kind"])
		by[k] = float(by.get(k, 0.0)) + float(e.get("rate", 0.0))
	var out: Array = []
	for k2 in by.keys():
		out.append({"kind": k2, "rate": float(by[k2])})
	return out


## How hard a machine is running: live wire rate ÷ listed rate over its
## wired material inputs (the median, so one odd port does not decide).
static func _run_share(listed: Array, wired: Array) -> float:
	var live: Dictionary = {}
	for w in wired:
		live[str(w["kind"])] = float(live.get(str(w["kind"]), 0.0)) + float(w.get("rate", 0.0))
	var shares: Array = []
	for i in listed:
		var d: Dictionary = i
		var k := str(d.get("kind", ""))
		var r := float(d.get("rate", 0.0))
		if r > 0.0 and live.has(k):
			shares.append(float(live[k]) / r)
	if shares.is_empty():
		return 0.0
	shares.sort()
	return float(shares[shares.size() / 2])



static func _leaks(items: Array, inflow_to: Dictionary, out: Dictionary) -> void:
	var leaks: Array = out["leaks"]
	for it in items:
		var d: Dictionary = it
		var specs: Dictionary = d.get("specs", {})
		var name := str(specs.get("name", d.get("id", "")))
		var kinds: Variant = specs.get("output_unconnected_kinds", [])
		if kinds is Array and not (kinds as Array).is_empty():
			var mat: Array = []
			for k in kinds:
				if CompositionCatalog.is_material(str(k)):
					mat.append(str(k))
			if not mat.is_empty():
				leaks.append({"id": str(d.get("id", "")), "name": name, "what": "nowhere_to_go", "kinds": mat})
		if str(d.get("type", "")) == "resource" and not bool(specs.get("unlimited_capacity", false)) \
				and not bool(specs.get("outlet_sink", false)) \
				and float(specs.get("level", 0.0)) >= FULL_LEVEL \
				and float(inflow_to.get(str(d.get("id", "")), 0.0)) > 1e-6:
			leaks.append({"id": str(d.get("id", "")), "name": name, "what": "full",
				"kinds": [str(specs.get("resource_kind", ""))]})


# --- words --------------------------------------------------------------------

static func fmt_kg(kg: float) -> String:
	var a := absf(kg)
	if a >= 1000.0:
		return "%s t" % _num(kg / 1000.0)
	if a >= 1.0 or a == 0.0:
		return "%s kg" % _num(kg)
	return "%s g" % _num(kg * 1000.0)


static func fmt_kg_h(kg_h: float) -> String:
	# A day reads better than an hour for slow flows.
	if absf(kg_h) < 0.1:
		return "%s/day" % fmt_kg(kg_h * 24.0)
	return "%s/h" % fmt_kg(kg_h)


static func fmt_water_l(kg: float) -> String:
	return UiText.num(kg, "L")


static func fmt_energy_mj(mj: float) -> String:
	if absf(mj) >= 3.6:
		return UiText.num(mj / 3.6 * 1000.0, "Wh")
	return "%s MJ" % _num(mj)


static func _num(v: float) -> String:
	var a := absf(v)
	if a >= 100.0:
		return UiText.thousands(int(round(v)))
	if a >= 10.0:
		return "%.1f" % v
	if a >= 1.0:
		return "%.2f" % v
	return "%.3f" % v


const ELEMENT_NAMES := {"C": "Carbon", "N": "Nitrogen", "P": "Phosphorus", "K": "Potassium",
	"H": "Hydrogen", "O": "Oxygen", "S": "Sulfur", "Na": "Sodium", "Cl": "Chlorine"}


## Dashboard rows in SiteBalance's shape ({t: kv | sub | note | alert, k, v, tone}).
static func rows(led: Dictionary) -> Array:
	var r: Array = []
	var st: Dictionary = led.get("stock", {})
	var w: Dictionary = led.get("water", {})
	var stores: Array = led.get("stores", [])
	if stores.is_empty() and (led.get("nodes", {}) as Dictionary).is_empty():
		return r
	r.append({"t": "sub", "text": "Water"})
	r.append({"t": "kv", "k": "Usable water stored", "v": fmt_water_l(float(st.get("usable_water_kg", 0.0)))})
	var bound := float(st.get("bound_water_kg", 0.0))
	if bound > 0.5:
		var bk: Dictionary = st.get("bound_by_kind", {})
		var ks: Array = bk.keys()
		ks.sort_custom(func(a, b) -> bool: return float(bk[a]) > float(bk[b]))
		var names := PackedStringArray()
		for k in ks.slice(0, 3):
			names.append(ResourceKinds.display_name(str(k)).to_lower())
		r.append({"t": "kv", "k": "Water in other stores", "v": fmt_water_l(bound)})
		r.append({"t": "note", "k": "", "v": "held in " + ", ".join(names), "tone": "muted"})
	var ratio := float(w.get("ratio", NAN))
	if is_nan(ratio):
		r.append({"t": "kv", "k": "Water recovery", "v": "—", "tone": "muted"})
		r.append({"t": "note", "k": "", "v": "no used water is flowing", "tone": "muted"})
	else:
		r.append({"t": "kv", "k": "Water recovery", "v": UiText.pct(ratio),
			"tone": "ok" if ratio >= 0.9 else ("warn" if ratio < 0.5 else "")})
		r.append({"t": "kv", "k": "Used water", "v": UiText.num(float(w.get("used_kg_h", 0.0)) * 24.0, "L") + "/day", "tone": "muted"})
		r.append({"t": "kv", "k": "Comes back clean", "v": UiText.num(float(w.get("recovered_kg_h", 0.0)) * 24.0, "L") + "/day", "tone": "muted"})
	r.append({"t": "sub", "text": "Held in stores"})
	var el: Dictionary = st.get("elements", {})
	for e in REPORT_ELEMENTS:
		r.append({"t": "kv", "k": str(ELEMENT_NAMES.get(e, e)), "v": fmt_kg(float(el.get(e, 0.0)))})
	var mj := float(st.get("energy_mj", 0.0))
	if mj > 0.0:
		r.append({"t": "kv", "k": "Fuel energy", "v": fmt_energy_mj(mj)})
	var food := float(st.get("food_mj", 0.0))
	if food > 0.0:
		r.append({"t": "kv", "k": "Food energy", "v": "%s kcal" % UiText.thousands(int(round(food * 239.006)))})
	var gases: Dictionary = (led.get("air", {}) as Dictionary).get("gases", {})
	var gnames: Array = []
	for g in gases.keys():
		if absf(float(gases[g])) >= UNACCOUNTED_MIN_KG_H:
			gnames.append(g)
	if not gnames.is_empty():
		gnames.sort_custom(func(a, b) -> bool: return absf(float(gases[a])) > absf(float(gases[b])))
		r.append({"t": "sub", "text": "Air"})
		for g2 in gnames.slice(0, 4):
			var kg := float(gases[g2])
			r.append({"t": "kv", "k": str(GAS_NAMES.get(g2, g2)),
				"v": ("gives off " if kg > 0.0 else "takes in ") + fmt_kg_h(absf(kg)), "tone": "muted"})
	var dumped: Dictionary = led.get("dumped", {})
	if float(dumped.get("kg_h", 0.0)) > UNACCOUNTED_MIN_KG_H:
		r.append({"t": "kv", "k": "Drained off site", "v": fmt_kg_h(float(dumped["kg_h"])), "tone": "muted"})
	var unacc: Array = led.get("unaccounted", [])
	if not unacc.is_empty():
		r.append({"t": "sub", "text": "Doesn't add up"})
		for u in unacc.slice(0, 3):
			r.append({"t": "note", "k": str(u["name"]), "v": unaccounted_text(u),
				"tone": "warn" if _creates(u) else "muted"})
	var leaks: Array = led.get("leaks", [])
	if not leaks.is_empty():
		var parts := PackedStringArray()
		for lk in leaks.slice(0, 3):
			var kinds := PackedStringArray()
			for k2 in lk["kinds"]:
				kinds.append(ResourceKinds.display_name(str(k2)).to_lower())
			parts.append("%s: %s %s" % [str(lk["name"]), ", ".join(kinds),
				"has nowhere to go" if str(lk["what"]) == "nowhere_to_go" else "store is full and spilling"])
		r.append({"t": "note", "k": "Lost", "v": "; ".join(parts), "tone": "warn"})
	var unknown: Array = led.get("unknown", [])
	if not unknown.is_empty():
		var names2 := PackedStringArray()
		for u2 in unknown.slice(0, 3):
			names2.append(str(u2["name"]))
		r.append({"t": "note", "k": "Not counted (make-up unknown)", "v": ", ".join(names2), "tone": "muted"})
	return r


const GAS_NAMES := {"CO2": "Carbon dioxide", "O2": "Oxygen", "H2O": "Water vapour",
	"CH4": "Methane", "NH3": "Ammonia", "N2": "Nitrogen gas"}


static func _creates(u: Dictionary) -> bool:
	for k in (u["deltas"] as Dictionary).keys():
		if str(k) != "water" and float(u["deltas"][k]) > 0.0:
			return true
	return false


## "makes 1.1 kg/h N from nothing · 0.8 kg/h C unaccounted (to air?)"
static func unaccounted_text(u: Dictionary) -> String:
	var parts := PackedStringArray()
	var d: Dictionary = u.get("deltas", {})
	for k in MassBalance.MAIN_ELEMENTS:
		if not d.has(k):
			continue
		var v := float(d[k])
		var nm := str(ELEMENT_NAMES.get(k, k)).to_lower()
		if v > 0.0:
			parts.append("makes %s %s from nothing" % [fmt_kg_h(v), nm])
		else:
			parts.append("%s %s goes missing" % [fmt_kg_h(-v), nm])
	if d.has("water"):
		var wv := float(d["water"])
		parts.append(("%s more water out than in" if wv > 0.0 else "%s of water goes missing") % (UiText.num(absf(wv), "L") + "/h"))
	return " · ".join(parts)
