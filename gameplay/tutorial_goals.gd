class_name TutorialGoals
extends RefCounted

## Pure goal-predicate evaluator for Solar Bootcamp levels. Everything here is
## a function of graph TOPOLOGY (ratings, not live sun), so goals read the same
## at midnight as at noon and the whole thing selftests offline:
## "deliverable" watts = min(array rated W, bus_V × controller amps) — the
## capacity the wiring permits, per GraphDcElectrical.controller_throttle.
##
## ctx = {model, flat_conns, analysis, faults: {reason: true}} — the director
## builds it once per evaluation; the selftest builds it from synthetic models.


static func build_ctx(model: GraphModel, faults: Dictionary = {}) -> Dictionary:
	var flat := GraphNesting.flat_connections(model)
	return {
		"model": model,
		"flat_conns": flat,
		"analysis": GraphDcElectrical.analyze(model, flat),
		"faults": faults,
	}


## Returns {met: bool, progress: String}. Unknown kinds never complete.
static func evaluate(goal: Dictionary, ctx: Dictionary) -> Dictionary:
	match str(goal.get("kind", "")):
		"fault_observed":
			var reason := str(goal.get("reason", ""))
			var seen: Dictionary = ctx.get("faults", {}) as Dictionary
			return {
				"met": seen.has(reason),
				"progress": "Waiting for the inevitable…" if not seen.has(reason) else "Kaboom.",
			}
		"build":
			return _evaluate_build(goal, ctx)
		"run_clean":
			# Run-level goals are decided by the DIRECTOR from bake results
			# (evaluate_run below); topology evaluation just prompts the run.
			return {"met": false, "progress": "Press ▶ Run 24 h when you're ready"}
		"ac_load_wired":
			var model: GraphModel = ctx.get("model")
			var ok := ac_load_wired(model, ctx.get("flat_conns", []) as Array) \
					and not any_destroyed(model)
			return {
				"met": ok,
				"progress": "Appliance powered ✓" if ok
						else "Wire an appliance to the controller's AC output",
			}
		"compound_containing":
			var m2: GraphModel = ctx.get("model")
			var types: Array = goal.get("types", []) as Array
			var ok2 := compound_containing(m2, types)
			return {
				"met": ok2,
				"progress": "Combined ✓" if ok2
						else "Select the parts and press Ctrl+G to combine them",
			}
	return {"met": false, "progress": ""}


## True when an appliance/acload draws from a controller's AC output (the
## controller doubles as the inverter in this graph), directly or via
## breaker-panel style AC distribution (one pass-through hop).
static func ac_load_wired(model: GraphModel, flat: Array) -> bool:
	if model == null:
		return false
	var ac_fed: Dictionary = {}  # item_id fed from a controller AC handle
	for conn in flat:
		if not (conn is Dictionary):
			continue
		var c: Dictionary = conn
		for side in [["source_item_id", "source_handle_id", "target_item_id"],
				["target_item_id", "target_handle_id", "source_item_id"]]:
			var from_item := model.get_item(str(c.get(side[0], "")))
			if from_item.is_empty():
				continue
			if str(from_item.get("type", "")) == "controller" \
					and str(c.get(side[1], "")).begins_with("acOutput") \
					and not bool(from_item.get("is_virtual", false)):
				ac_fed[str(c.get(side[2], ""))] = true
	if ac_fed.is_empty():
		return false
	# Direct hit, or one distribution hop (breaker panel / spiderbox / outlet).
	for iid in ac_fed:
		var it := model.get_item(str(iid))
		var ty := str(it.get("type", ""))
		if ty == "appliance" or ty == "acload":
			return true
	for conn in flat:
		if not (conn is Dictionary):
			continue
		var c2: Dictionary = conn
		var a := str(c2.get("source_item_id", ""))
		var b := str(c2.get("target_item_id", ""))
		for pair in [[a, b], [b, a]]:
			if ac_fed.has(str(pair[0])):
				var tgt := model.get_item(str(pair[1]))
				var tt := str(tgt.get("type", ""))
				if tt == "appliance" or tt == "acload":
					return true
	return false


## True when some compound's child scope contains at least one item of every
## required type (the "merge into one box" lesson).
static func compound_containing(model: GraphModel, types: Array) -> bool:
	if model == null or types.is_empty():
		return false
	for item in GraphNesting.walk_items(model, "root"):
		if not (item is Dictionary):
			continue
		var it: Dictionary = item
		if str(it.get("type", "")) != "compound":
			continue
		var scope := str(it.get("child_scope_id", ""))
		if scope.is_empty():
			continue
		var have: Dictionary = {}
		for child in model.get_items_in_scope(scope):
			have[str((child as Dictionary).get("type", ""))] = true
		var all := true
		for t in types:
			if not have.has(str(t)):
				all = false
				break
		if all:
			return true
	return false


static func _evaluate_build(goal: Dictionary, ctx: Dictionary) -> Dictionary:
	var model: GraphModel = ctx.get("model")
	var flat: Array = ctx.get("flat_conns", []) as Array
	var analysis: Dictionary = ctx.get("analysis", {}) as Dictionary
	var parts: Array[String] = []
	var met := true

	# Build goals always require a clean system (a destroyed node = not done).
	if any_destroyed(model):
		return {"met": false, "progress": "Something is destroyed — press RESET and fix the wiring"}

	var min_w := float(goal.get("min_deliverable_w", 0.0))
	var deliv := deliverable(model, flat, analysis)
	if min_w > 0.0:
		var d := float(deliv.get("deliverable_w", 0.0))
		parts.append("Deliverable: %.0f / %.0f W" % [d, min_w])
		if d < min_w:
			met = false

	var min_v := float(goal.get("min_bus_v", 0.0))
	if min_v > 0.0:
		var bus := max_bus_voltage(analysis)
		parts.append("Bank: %.0f V (need %.0f V)" % [bus, min_v])
		if bus < min_v - 0.5:
			met = false

	var want_s := int(goal.get("series", 0))
	var want_p := int(goal.get("parallel", 0))
	if want_s > 0 and want_p > 0:
		var ok := array_config_matches(model, flat, want_s, want_p)
		parts.append("Array: %s %dS%dP" % ["✓" if ok else "need", want_s, want_p])
		if not ok:
			met = false

	return {"met": met, "progress": "  ·  ".join(parts)}


## Run-level verdict from a ChallengeBakeEngine run_succeeded payload.
## Reaching this at all means the run finished with no failure; the optional
## threshold is on USEFUL utilization (loads served + charge banked vs what
## the sky offered — see the bake engine).
static func evaluate_run(goal: Dictionary, bake_result: Dictionary) -> Dictionary:
	var min_util := float(goal.get("min_useful_utilization_pct", 0.0))
	var util := float(bake_result.get("useful_utilization_pct", 0.0))
	if min_util > 0.0 and util + 1e-6 < min_util:
		return {"met": false,
			"progress": "Clean run, but only %.0f%% of the sun did work (need %.0f%%) — add or automate loads and run again" % [util, min_util]}
	return {"met": true, "progress": "Clean run — %.0f%% of the sun put to work" % util}


static func any_destroyed(model: GraphModel) -> bool:
	for item in GraphNesting.walk_items(model, "root"):
		if item is Dictionary \
				and bool(((item as Dictionary).get("specs", {}) as Dictionary).get("destroyed", false)):
			return true
	return false


## Σ over real controllers of min(attached array rated W, bus_V × I_max).
## Returns {deliverable_w, array_w}.
static func deliverable(model: GraphModel, flat: Array, analysis: Dictionary) -> Dictionary:
	var total := 0.0
	var array_total := 0.0
	for item in GraphNesting.walk_items(model, "root"):
		if not (item is Dictionary):
			continue
		var it: Dictionary = item
		if str(it.get("type", "")) != "controller" or bool(it.get("is_virtual", false)):
			continue
		if bool((it.get("specs", {}) as Dictionary).get("destroyed", false)):
			continue
		var cid := str(it.get("id", ""))
		var bank := GraphDcElectrical.bank_for_controller(model, cid, flat, analysis)
		if bank.is_empty():
			continue
		# Backwards PV leads deliver nothing, so a level's watt goal must not be
		# satisfiable by a crossed pair (it used to be: the Voc math is a
		# magnitude sum and both legs still resolved).
		if GraphDcElectrical.controller_pv_reversed(model, cid, flat):
			continue
		var wmp := 0.0
		for sid in PvElectrical.pv_sources_for_controller_flat(model, cid, flat):
			var src := model.get_item(str(sid))
			wmp += float((src.get("specs", {}) as Dictionary).get("wmp", 0.0))
		if wmp <= 0.0:
			continue
		array_total += wmp
		var th := GraphDcElectrical.controller_throttle(it, bank, wmp)
		total += float(th.get("delivered_w", 0.0))
	return {"deliverable_w": total, "array_w": array_total}


static func max_bus_voltage(analysis: Dictionary) -> float:
	var best := 0.0
	for bank in analysis.get("banks", []) as Array:
		best = maxf(best, float((bank as Dictionary).get("bus_voltage", 0.0)))
	return best


## True when some controller's PV feed is wired as `series`S × `parallel`P:
## exactly `parallel` series-strings, each of exactly `series` panels.
static func array_config_matches(model: GraphModel, flat: Array,
		series: int, parallel: int) -> bool:
	for item in GraphNesting.walk_items(model, "root"):
		if not (item is Dictionary):
			continue
		var it: Dictionary = item
		if str(it.get("type", "")) != "controller" or bool(it.get("is_virtual", false)):
			continue
		var sources := PvElectrical.pv_sources_for_controller_flat(
			model, str(it.get("id", "")), flat)
		if sources.is_empty():
			continue
		var comps := PvElectrical.connected_components(sources, flat, true)
		if comps.size() != parallel:
			continue
		var all_match := true
		for comp in comps:
			if (comp as Array).size() != series:
				all_match = false
				break
		if all_match:
			return true
	return false
