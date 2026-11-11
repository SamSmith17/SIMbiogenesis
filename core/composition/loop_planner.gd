class_name LoopPlanner
extends RefCounted

## Chains of machines that close a site's open loops (resource composition
## plan Phase 6). Pure and deterministic.
##
## THE LIBRARY is a hypergraph: kinds are nodes, every preset, builtin
## recipe and (for jobs no machine does) unit-operation class is an edge
## with ALL its inputs (AND) and all its outputs, in kg at its listed rates
## (library()). A class edge is the class applied to one kind it accepts:
## what it pulls out, at its typical recovery.
##
## OPEN LOOPS (find_open): per kind, what the scope's machines, people and
## plants make against what they use, at their listed rates.
##   sink    made and not used (greywater with nowhere to go)
##   source  used and not made (food brought in, water drawn from a store)
## Ranked by kg/h × what the kind carries (water, and N P K far more).
##
## THE SEARCH (plan): best-first with a beam, depth ≤ MAX_STEPS.
##   sink: from the open kind forward, each step an edge that takes in what
##         is still open; done when everything open has reached a GOAL (a
##         kind the scope uses, a benign sink: soil, compost, irrigation
##         water, nutrients, the air).
##   source: from the wanted kind backward, each step an edge that makes
##         what is still wanted; done when every input is a kind the scope
##         has (a store, a machine making it, an open sink: better still).
##   A co-input the scope does not have becomes a NEED (a sub-goal the
##   plan reports); a by-product that is no goal stays STILL OPEN.
##   Cost = steps + energy + price + what is left open + needs + a class
##   with no machine + an unbalanced machine; ties on the edge ids, so two
##   runs give the same plans.
## A plan: {steps: [{id, type, label, scale (× the edge's listed rates),
## takes: kind, gives: [kinds]}], closes (share of the open flow that
## reaches a goal), adds: {power_w, cost}, still_open: [{kind, kg_h}],
## needs: [{kind, kg_h}], complete, cost}.

const MAX_STEPS := 4
const BEAM := 32
const MAX_PLANS := 3
## Kinds that may safely end a chain whether or not the scope uses them.
const BENIGN := ["soil", "compost", "biochar", "irrigation_water", "nutrients", "air"]
## Kinds whose ordinary end is a store, not a machine: a plan may end on one
## and the store is added with it (ChainWiring) when the scope has none.
const TERMINAL := {"brine": "Salt Pan (brine)"}
## Clean water kinds that answer a need for water.
const WATER_KINDS := ["water", "distilled_water", "rainwater", "irrigation_water"]
const W_STEP := 1.0
const W_ENERGY := 2.0      # per kWh per kg of the open flow (boiling greywater must lose to filtering it)
const W_PRICE := 0.0002    # per $ per kg/h of the open flow (capital per throughput)
const W_LEFT := 3.0        # per share left open
const W_NEED := 2.0        # per share of co-inputs the scope lacks
const W_CLASS := 1.5       # a step with no machine yet
const W_UNBALANCED := 1.0
const W_INCOMPLETE := 1.5  # anything at all left open or needed
## A loop smaller than this (kg/h) is not open, it is rounding.
const MIN_OPEN_KG_H := 0.002
## Prefix of the open residue a class with no reject kind leaves.
const RESIDUE := "residue:"

static var _lib: Dictionary = {}
static var _lib_sig := ""


# --- the library ----------------------------------------------------------------

## The game's library as edges, cached until it changes.
static func library() -> Dictionary:
	var presets := ProcessCapabilities._library_presets()
	var sig := "%d|%d" % [presets.size(), hash(JSON.stringify(ProcessCapabilities._labels(presets)))]
	if sig == _lib_sig and not _lib.is_empty():
		return _lib
	_lib = build_library(presets, ProcessRecipeCatalog.BUILTINS, true)
	_lib_sig = sig
	return _lib


## Edges from presets (ComponentPresets shape), recipes (ProcessRecipe
## shape) and, if `classes`, every UnitOps class on every kind it accepts.
## → {edges: [edge], by_in: {kind: [i]}, by_out: {kind: [i]}}
static func build_library(presets: Array, recipes: Array, classes: bool) -> Dictionary:
	var edges: Array = []
	for p in presets:
		var pd: Dictionary = p
		var sp: Dictionary = pd.get("specs", {})
		if str(sp.get("role", "")) == "habitat":
			continue
		# A delivery (a water truck, food brought in) is the import a plan
		# exists to replace, never a way to close a loop.
		if str(sp.get("role", "")) == "import" or bool(sp.get("counts_as_import", false)):
			continue
		var ins: Array = sp.get("inputs", [])
		var outs: Array = sp.get("outputs", [])
		if str(pd.get("type", "")) == "plant":
			var io := MassBalance.plant_io(sp)
			ins = io[0]
			outs = io[1]
		var item := {"type": str(pd.get("type", "processor")), "specs": sp}
		var e := _edge("preset:" + str(pd.get("label", "")), "preset", str(pd.get("label", "")), ins, outs,
			ProcessCapabilities._power_kw(sp), float(sp.get("cost", 0.0)), sp.get("unit_ops", []))
		if e.is_empty():
			continue
		e["balanced"] = str(MassBalance.of_item(item)["verdict"]) != "unbalanced"
		edges.append(e)
	for r in recipes:
		var rd: Dictionary = r
		var routs: Array = []
		for o in rd.get("outputs", []):
			var od: Dictionary = (o as Dictionary).duplicate()
			if str(od.get("kind", "")) == "part":
				od["kind"] = "finished_part"
			routs.append(od)
		var kwh := 0.0
		for i in rd.get("inputs", []):
			if str((i as Dictionary).get("kind", "")) == "electric":
				kwh += float((i as Dictionary).get("qty", 0.0)) / 1000.0
		var re := _edge("recipe:" + str(rd.get("label", rd.get("id", ""))), "recipe",
			str(rd.get("label", rd.get("id", ""))), rd.get("inputs", []), routs, kwh, 0.0, [])
		if not re.is_empty():
			re["balanced"] = true
			edges.append(re)
	if classes:
		var kinds := CompositionData.KINDS.keys()
		kinds.sort()
		var ids := UnitOps.CLASSES.keys()
		ids.sort()
		for cid in ids:
			var row: Dictionary = UnitOps.CLASSES[cid]
			if (row.get("gives", []) as Array).is_empty():
				continue
			for k in kinds:
				var kind := str(k)
				if not UnitOps.accepts(str(cid), kind) or not CompositionCatalog.is_material(kind):
					continue
				var ce := _class_edge(str(cid), row, kind)
				if not ce.is_empty():
					edges.append(ce)
	edges.sort_custom(func(a, b) -> bool: return str(a["id"]) < str(b["id"]))
	var by_in: Dictionary = {}
	var by_out: Dictionary = {}
	for i2 in edges.size():
		for k2 in (edges[i2]["ins"] as Dictionary).keys():
			if not by_in.has(k2):
				by_in[k2] = []
			(by_in[k2] as Array).append(i2)
		for k3 in (edges[i2]["outs"] as Dictionary).keys():
			if not by_out.has(k3):
				by_out[k3] = []
			(by_out[k3] as Array).append(i2)
	return {"edges": edges, "by_in": by_in, "by_out": by_out}


static func _edge(id: String, type: String, label: String, ins: Array, outs: Array, kwh: float,
		cost: float, classes: Variant) -> Dictionary:
	var ik := _kg_map(ins)
	var ok := _kg_map(outs)
	if ik.is_empty() and ok.is_empty():
		return {}
	return {"id": id, "type": type, "label": label, "ins": ik, "outs": ok, "kwh": kwh, "cost": cost,
		"classes": classes if classes is Array else [], "balanced": true}


## One class applied to one kind: 1 kg in, each target out at its recovery
## (in kg of the kind it leaves in), the rest assumed handled by the class.
static func _class_edge(cid: String, row: Dictionary, kind: String) -> Dictionary:
	var per := CompositionCatalog.embodied_kg(kind, 1.0)
	if not bool(per.get("known", false)):
		return {}
	var outs: Dictionary = {}
	for g in row.get("gives", []):
		var gd: Dictionary = g
		var to := str(gd["to"])
		if to == kind:
			continue
		var t := str(gd["target"])
		var amt := float(per.get("water_kg", 0.0)) if t == "water" else float((per.get("elements", {}) as Dictionary).get(t, 0.0))
		amt *= float(gd["recovery"])
		if amt <= 0.0:
			continue
		var kg := amt
		if to != "air":
			var to_per := CompositionCatalog.embodied_kg(to, 1.0)
			var share := float(to_per.get("water_kg", 0.0)) if t == "water" else float((to_per.get("elements", {}) as Dictionary).get(t, 0.0))
			if share <= 0.0:
				continue
			kg = amt / share
		outs[to] = float(outs.get(to, 0.0)) + kg
	if outs.is_empty():
		return {}
	# The rest of the feed: into the class's reject kind, else an open
	# residue nothing takes (a class step must not look complete for free).
	var out_kg := 0.0
	for o in outs.keys():
		out_kg += float(outs[o])
	var rest := maxf(1.0 - out_kg, 0.0)
	if rest > 0.01:
		var rej := str(row.get("reject", ""))
		if rej.is_empty():
			outs[RESIDUE + kind] = rest
		elif rej != kind:
			outs[rej] = float(outs.get(rej, 0.0)) + rest
	var kwh := float(row["kwh_per_kg"])
	if str(row.get("per", "feed")) == "water":
		kwh *= float(per.get("water_kg", 0.0))
	return {"id": "class:%s:%s" % [cid, kind], "type": "class", "label": str(row["label"]),
		"class": cid, "ins": {kind: 1.0}, "outs": outs, "kwh": kwh, "cost": 0.0, "classes": [cid],
		"balanced": true}


## {kind: kg} of an io list (material kinds only, in kg at the listed rate).
static func _kg_map(ios: Array) -> Dictionary:
	var out: Dictionary = {}
	for io in ios:
		var d: Dictionary = io
		var kind := CompositionCatalog.canonical(ResourceKinds.normalize_kind(str(d.get("kind", ""))))
		var q := float(d.get("rate", d.get("qty", 0.0)))
		if q <= 0.0 or not CompositionCatalog.is_material(kind):
			continue
		out[kind] = float(out.get(kind, 0.0)) + q * CompositionCatalog.kg_per_unit(kind)
	return out


# --- open loops -------------------------------------------------------------------

## What the scope makes and uses per kind at its listed rates, and what is
## left open. → {made: {kind: kg/h}, used: {kind: kg/h}, stocked: {kind: true},
## open: [{kind, side, kg_h, value, rank}]}
static func find_open(model: GraphModel, scope_id: String = "root") -> Dictionary:
	var made: Dictionary = {}
	var used: Dictionary = {}
	var stocked: Dictionary = {}
	var flex: Dictionary = {}
	if model == null:
		return {"made": made, "used": used, "stocked": stocked, "open": []}
	for it in GraphNesting.walk_items(model, scope_id):
		var d: Dictionary = it
		if bool(d.get("is_ghost", false)):
			continue
		var sp: Dictionary = d.get("specs", {})
		var ty := str(d.get("type", ""))
		if ty == "resource":
			var rk := CompositionCatalog.canonical(ResourceKinds.normalize_kind(str(sp.get("resource_kind", ""))))
			if CompositionCatalog.is_material(rk) and (ResourceKinds.tank_stock_qty(sp) > 0.0
					or bool(sp.get("unlimited_capacity", false))):
				stocked[rk] = true
			continue
		if ty == "catchment":
			_add(made, "water", float(sp.get("live_capture_lph", 0.0)))
			continue
		if ty != "processor" and ty != "plant":
			continue
		var mult := maxf(float(sp.get("occupants", 1.0)), 1.0) if str(sp.get("role", "")) == "habitat" else 1.0
		var ins: Array = sp.get("inputs", [])
		var outs: Array = sp.get("outputs", [])
		if ty == "plant":
			var crop := maxf(float(sp.get("biomass_kg_h", 0.0)), 0.0)
			var io := MassBalance.plant_io(sp)
			for i in io[0]:
				_add(used, str(i["kind"]), float(i["rate"]) * crop)
			for o in io[1]:
				_add(made, str(o["kind"]), float(o["rate"]) * crop)
			continue
		if str(sp.get("role", "")) == "habitat":
			# An input listed at rate 0 is one the people's own sim sets
			# (meals): they eat whatever is made of it.
			for inp in ins:
				if float((inp as Dictionary).get("rate", 0.0)) <= 0.0:
					flex[CompositionCatalog.canonical(ResourceKinds.normalize_kind(str(inp.get("kind", ""))))] = true
		for k in _kg_map(ins).keys():
			_add(used, k, float(_kg_map(ins)[k]) * mult)
		var om := _kg_map(outs)
		for k2 in om.keys():
			_add(made, k2, float(om[k2]) * mult)
	for fk in flex.keys():
		if made.has(fk):
			used[fk] = maxf(float(used.get(fk, 0.0)), float(made[fk]))
	var open: Array = []
	for k3 in made.keys():
		var left := float(made[k3]) - float(used.get(k3, 0.0))
		if left > maxf(MIN_OPEN_KG_H, 0.01 * float(made[k3])) and not BENIGN.has(k3):
			open.append(_open_row(str(k3), "sink", left))
	for k4 in used.keys():
		var lack := float(used[k4]) - float(made.get(k4, 0.0))
		if k4 == "water":
			for wk in WATER_KINDS:
				if wk != "water":
					lack -= float(made.get(wk, 0.0))
		if lack > maxf(MIN_OPEN_KG_H, 0.01 * float(used[k4])):
			open.append(_open_row(str(k4), "source", lack))
	open.sort_custom(func(a, b) -> bool:
		if absf(float(a["rank"]) - float(b["rank"])) > 1e-9:
			return float(a["rank"]) > float(b["rank"])
		return str(a["kind"]) + str(a["side"]) < str(b["kind"]) + str(b["side"]))
	return {"made": made, "used": used, "stocked": stocked, "open": open}


static func _add(d: Dictionary, kind: String, kg: float) -> void:
	if kg <= 0.0:
		return
	var k := CompositionCatalog.canonical(ResourceKinds.normalize_kind(kind))
	d[k] = float(d.get(k, 0.0)) + kg


static func _open_row(kind: String, side: String, kg_h: float) -> Dictionary:
	var v := value_per_kg(kind)
	return {"kind": kind, "side": side, "kg_h": kg_h, "value": v, "rank": kg_h * v}


## What a kg of the kind carries worth closing: its water, and its N, P and
## K at fifty times that (they are what runs out first).
static func value_per_kg(kind: String) -> float:
	var per := CompositionCatalog.embodied_kg(kind, 1.0)
	if not bool(per.get("known", false)):
		return 0.2
	var el: Dictionary = per.get("elements", {})
	return 0.2 + float(per.get("water_kg", 0.0)) \
		+ 50.0 * (float(el.get("N", 0.0)) + float(el.get("P", 0.0)) + float(el.get("K", 0.0)))


# --- the search -----------------------------------------------------------------

## Plans for one open loop. `ctx` = {used: {kind}, stocked: {kind},
## made: {kind}, sinks: {kind}} (find_open's maps; `sinks` = the scope's
## open sink kinds, which a source plan may draw on).
static func plan(lib: Dictionary, kind: String, side: String, kg_h: float, ctx: Dictionary) -> Array:
	var k := CompositionCatalog.canonical(ResourceKinds.normalize_kind(kind))
	if kg_h <= 0.0:
		return []
	var start := {"open": {k: kg_h}, "steps": [], "used_edges": {}, "left_closed": 0.0, "needs": {},
		"kwh": 0.0, "cost": 0.0, "classes": 0, "unbalanced": 0}
	var beam: Array = [start]
	var done: Array = []
	for depth in MAX_STEPS:
		var next: Array = []
		for st in beam:
			next.append_array(_expand(lib, st, side, k, kg_h, ctx))
		if next.is_empty():
			break
		for s in next:
			s["f"] = _cost(s, kg_h)
		next.sort_custom(_by_cost)
		var kept: Array = []
		for s2 in next:
			if (s2["open"] as Dictionary).is_empty():
				done.append(s2)
			elif kept.size() < BEAM:
				kept.append(s2)
			# Partial plans are kept as answers too (a step that closes most).
			if not (s2["open"] as Dictionary).is_empty() and done.size() + kept.size() <= BEAM * 4:
				done.append(s2)
		beam = kept
	done.sort_custom(_by_cost)
	var out: Array = []
	var seen: Dictionary = {}
	for s3 in done:
		var sig := ",".join(PackedStringArray((s3["steps"] as Array).map(func(x): return str(x["id"]))))
		if seen.has(sig):
			continue
		seen[sig] = true
		out.append(_result(s3, side, k, kg_h))
		if out.size() >= MAX_PLANS:
			break
	return out


static func _expand(lib: Dictionary, st: Dictionary, side: String, target: String, f0: float, ctx: Dictionary) -> Array:
	var open: Dictionary = st["open"]
	# Work on the biggest open kind (ties by name).
	var ks := open.keys()
	ks.sort_custom(func(a, b) -> bool:
		if absf(float(open[a]) - float(open[b])) > 1e-12:
			return float(open[a]) > float(open[b])
		return str(a) < str(b))
	var kind := str(ks[0])
	var amt := float(open[kind])
	var idx: Array = (lib["by_in"] if side == "sink" else lib["by_out"]).get(kind, [])
	var out: Array = []
	for i in idx:
		var e: Dictionary = lib["edges"][i]
		if (st["used_edges"] as Dictionary).has(str(e["id"])):
			continue
		var here := float((e["ins"] if side == "sink" else e["outs"])[kind])
		if here <= 0.0:
			continue
		var scale := amt / here
		var n := {"open": open.duplicate(), "steps": (st["steps"] as Array).duplicate(),
			"used_edges": (st["used_edges"] as Dictionary).duplicate(), "left_closed": float(st["left_closed"]),
			"needs": (st["needs"] as Dictionary).duplicate(), "kwh": float(st["kwh"]) + float(e["kwh"]) * scale,
			"cost": float(st["cost"]) + float(e["cost"]) * scale, "classes": int(st["classes"]) + (1 if str(e["type"]) == "class" else 0),
			"unbalanced": int(st["unbalanced"]) + (0 if bool(e["balanced"]) else 1)}
		n["used_edges"][str(e["id"])] = true
		(n["open"] as Dictionary).erase(kind)
		var gives: Array = []
		if side == "sink":
			for o in (e["outs"] as Dictionary).keys():
				var okg := float(e["outs"][o]) * scale
				gives.append(str(o))
				if _is_goal(str(o), target, ctx):
					continue
				n["open"][o] = float(n["open"].get(o, 0.0)) + okg
			for c in (e["ins"] as Dictionary).keys():
				if str(c) == kind:
					continue
				_need(n, str(c), float(e["ins"][c]) * scale, ctx, side)
		else:
			for c2 in (e["ins"] as Dictionary).keys():
				_need(n, str(c2), float(e["ins"][c2]) * scale, ctx, side)
			for o2 in (e["outs"] as Dictionary).keys():
				gives.append(str(o2))
				if str(o2) == kind:
					continue
				# A by-product of a source plan: fine if the scope uses it
				# or it is benign, else it is something new left open.
				if not _is_goal(str(o2), target, ctx):
					n["left_closed"] = float(n["left_closed"]) + float(e["outs"][o2]) * scale
		(n["steps"] as Array).append({"id": str(e["id"]), "type": str(e["type"]), "label": str(e["label"]),
			"class": str(e.get("class", "")), "scale": scale, "takes": kind, "gives": gives,
			"classes": e["classes"]})
		out.append(n)
	return out


## A co-input of a step: the scope has it (a store, a machine making it, an
## open sink of it), else a source plan wants it next, else it is a need.
static func _need(n: Dictionary, kind: String, kg: float, ctx: Dictionary, side: String) -> void:
	if (ctx.get("stocked", {}) as Dictionary).has(kind) or (ctx.get("made", {}) as Dictionary).has(kind) \
			or (ctx.get("sinks", {}) as Dictionary).has(kind):
		return
	if (n["open"] as Dictionary).has(kind) and side == "sink":
		# The chain is making it already: use that.
		n["open"][kind] = maxf(float(n["open"][kind]) - kg, 0.0)
		if float(n["open"][kind]) <= 1e-12:
			(n["open"] as Dictionary).erase(kind)
		return
	if side == "source":
		n["open"][kind] = float(n["open"].get(kind, 0.0)) + kg
		return
	n["needs"][kind] = float(n["needs"].get(kind, 0.0)) + kg


static func _is_goal(kind: String, target: String, ctx: Dictionary) -> bool:
	if kind == target:
		return false
	if BENIGN.has(kind) or TERMINAL.has(kind):
		return true
	var used: Dictionary = ctx.get("used", {})
	if used.has(kind):
		return true
	return WATER_KINDS.has(kind) and used.has("water")


static func _cost(s: Dictionary, f0: float) -> float:
	var left := 0.0
	for k in (s["open"] as Dictionary).keys():
		left += float(s["open"][k])
	left += float(s["left_closed"])
	var need := 0.0
	for k2 in (s["needs"] as Dictionary).keys():
		need += float(s["needs"][k2])
	return W_STEP * float((s["steps"] as Array).size()) + W_ENERGY * float(s["kwh"]) / f0 \
		+ W_PRICE * float(s["cost"]) / maxf(f0, 1.0) + W_LEFT * clampf(left / f0, 0.0, 2.0) \
		+ W_NEED * clampf(need / f0, 0.0, 2.0) + W_CLASS * float(s["classes"]) \
		+ W_UNBALANCED * float(s["unbalanced"]) + (W_INCOMPLETE if left > 1e-9 or need > 1e-9 else 0.0)


static func _by_cost(a: Dictionary, b: Dictionary) -> bool:
	if absf(float(a["f"]) - float(b["f"])) > 1e-9:
		return float(a["f"]) < float(b["f"])
	var sa := ",".join(PackedStringArray((a["steps"] as Array).map(func(x): return str(x["id"]))))
	var sb := ",".join(PackedStringArray((b["steps"] as Array).map(func(x): return str(x["id"]))))
	return sa < sb


static func _result(s: Dictionary, side: String, kind: String, f0: float) -> Dictionary:
	var left := 0.0
	var still: Array = []
	for k in (s["open"] as Dictionary).keys():
		left += float(s["open"][k])
		still.append({"kind": str(k), "kg_h": float(s["open"][k])})
	var needs: Array = []
	for k2 in (s["needs"] as Dictionary).keys():
		needs.append({"kind": str(k2), "kg_h": float(s["needs"][k2])})
	var steps: Array = s["steps"]
	if side == "source":
		steps = steps.duplicate()
		steps.reverse()
	return {"side": side, "kind": kind, "kg_h": f0, "steps": steps,
		"closes": clampf(1.0 - (left + float(s["left_closed"])) / f0, 0.0, 1.0),
		"adds": {"power_w": float(s["kwh"]) * 1000.0, "cost": float(s["cost"])},
		"still_open": still, "needs": needs, "complete": still.is_empty() and needs.is_empty(),
		"cost": float(s.get("f", 0.0))}


# --- the whole scope ------------------------------------------------------------

## Every open loop in a scope with up to MAX_PLANS plans each, the most
## valuable first. → [{open: {kind, side, kg_h, …}, plans: [plan]}]
static func plan_scope(model: GraphModel, scope_id: String = "root", max_loops: int = 6, lib: Dictionary = {}) -> Array:
	var fo := find_open(model, scope_id)
	var use_lib := lib if not lib.is_empty() else library()
	var sinks: Dictionary = {}
	for o in fo["open"]:
		if str(o["side"]) == "sink":
			sinks[str(o["kind"])] = true
	var ctx := {"used": fo["used"], "made": fo["made"], "stocked": fo["stocked"], "sinks": sinks}
	var out: Array = []
	for o2 in (fo["open"] as Array).slice(0, max_loops):
		var od: Dictionary = o2
		var c2 := ctx.duplicate()
		if str(od["side"]) == "source":
			# A source plan must not lean on the store it is trying to replace.
			var st: Dictionary = (ctx["stocked"] as Dictionary).duplicate()
			st.erase(str(od["kind"]))
			c2["stocked"] = st
		out.append({"open": od, "plans": plan(use_lib, str(od["kind"]), str(od["side"]), float(od["kg_h"]), c2)})
	return out
