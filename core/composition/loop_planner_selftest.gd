extends SceneTree

## The loop planner (resource composition plan Phase 6), on a synthetic
## library and on the game's own. Offline:
##   Godot --headless --path . --script core/composition/loop_planner_selftest.gd
## Carries EXPECTED_CHECKS.

const EXPECTED_CHECKS := 23

var _checks := 0
var _fails := 0


func _check(name: String, cond: bool, detail: String = "") -> void:
	_checks += 1
	if cond:
		print("  ok   ", name)
	else:
		_fails += 1
		print("  FAIL ", name, ("  (" + detail + ")") if not detail.is_empty() else "")


func _p(label: String, ins: Array, outs: Array, watts: float = 0.0, cost: float = 0.0) -> Dictionary:
	var i2: Array = []
	for x in ins:
		i2.append({"kind": x[0], "rate": x[1]})
	var o2: Array = []
	for y in outs:
		o2.append({"kind": y[0], "rate": y[1]})
	return {"type": "processor", "label": label, "specs": {"inputs": i2, "outputs": o2, "watts": watts, "cost": cost}}


func _labels(plan: Dictionary) -> Array:
	var out: Array = []
	for s in plan["steps"]:
		out.append(str(s["label"]))
	return out


func _initialize() -> void:
	_test_synthetic()
	_test_real_library()
	_test_scope()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		push_error("FAIL: check count drifted — expected %d, ran %d (a runtime error aborted a test function?)" % [EXPECTED_CHECKS, _checks])
	if _fails == 0:
		print("LOOP PLANNER SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("LOOP PLANNER SELFTEST FAIL  (%d of %d checks failed)" % [_fails, _checks])
	quit(0 if _fails == 0 else 1)


func _test_synthetic() -> void:
	var presets := [
		_p("Digester", [["blackwater", 1.0]], [["liquid_fertilizer", 0.95], ["biogas", 0.02]], 10.0, 300.0),
		_p("Digestate Filter", [["liquid_fertilizer", 1.0]], [["irrigation_water", 0.95], ["nutrients", 0.002]], 20.0),
		_p("Gas Burner", [["biogas", 1.0]], [], 0.0, 50.0),
		_p("Mixer", [["food_waste", 1.0], ["biochar", 0.5]], [["soil", 1.5]], 50.0),
		_p("A to B", [["greywater", 1.0]], [["wash_water", 1.0]]),
		_p("B to C", [["wash_water", 1.0]], [["rainwater", 1.0]]),
		_p("C to D", [["rainwater", 1.0]], [["seawater", 1.0]]),
		_p("D to E", [["seawater", 1.0]], [["plastic_waste", 1.0]]),
		_p("E to F", [["plastic_waste", 1.0]], [["urine", 1.0]]),
		_p("F to G", [["urine", 1.0]], [["irrigation_water", 1.0]]),
	]
	var lib := LoopPlanner.build_library(presets, [], false)
	var ctx := {"used": {}, "made": {}, "stocked": {}, "sinks": {}}
	var bw := LoopPlanner.plan(lib, "blackwater", "sink", 5.0, ctx)
	_check("blackwater: a plan is found", not bw.is_empty())
	var best: Dictionary = bw[0] if not bw.is_empty() else {"steps": []}
	var labs := _labels(best)
	_check("blackwater → digester → filter, the biogas burned (3 steps)", labs.size() == 3 and labs.has("Digester")
		and labs.has("Digestate Filter") and labs.has("Gas Burner"), str(labs))
	_check("… and it closes the whole flow", bool(best.get("complete", false))
		and absf(float(best.get("closes", 0.0)) - 1.0) < 1e-6, "%.3f" % float(best.get("closes", 0.0)))
	var want_scale := 5.0 / CompositionCatalog.kg_per_unit("blackwater")
	_check("each step is sized to the open flow", absf(float(best["steps"][0]["scale"]) - want_scale) < 1e-4,
		"%.4f vs %.4f" % [float(best["steps"][0]["scale"]), want_scale])
	var mix := LoopPlanner.plan(lib, "food_waste", "sink", 2.0, ctx)
	var needs: Array = mix[0]["needs"] if not mix.is_empty() else []
	_check("an AND co-input the scope lacks (biochar) becomes a need", needs.size() == 1
		and str(needs[0]["kind"]) == "biochar" and absf(float(needs[0]["kg_h"]) - 1.0 * CompositionCatalog.kg_per_unit("biochar")) < 0.01,
		str(needs))
	var ctx2 := ctx.duplicate()
	ctx2["stocked"] = {"biochar": true}
	var mix2 := LoopPlanner.plan(lib, "food_waste", "sink", 2.0, ctx2)
	_check("… and none when the scope has it", not mix2.is_empty() and (mix2[0]["needs"] as Array).is_empty())
	var long := LoopPlanner.plan(lib, "greywater", "sink", 1.0, ctx)
	var longest := 0
	for pl in long:
		longest = maxi(longest, (pl["steps"] as Array).size())
	_check("the depth cap holds (≤ %d steps)" % LoopPlanner.MAX_STEPS, longest <= LoopPlanner.MAX_STEPS and longest > 0, "%d" % longest)
	_check("a six-step chain is reported partial, not complete", not long.is_empty() and not bool(long[0]["complete"]))
	_check("nothing takes steel: no plan", LoopPlanner.plan(lib, "steel", "sink", 1.0, ctx).is_empty())
	_check("two runs give the same plans", JSON.stringify(LoopPlanner.plan(lib, "blackwater", "sink", 5.0, ctx))
		== JSON.stringify(bw))
	# 200 presets: a deterministic jumble of real kinds.
	var kinds := ["water", "greywater", "blackwater", "urine", "food_waste", "biomass", "compost", "brine",
		"liquid_fertilizer", "irrigation_water", "biogas", "biochar", "wash_water", "seawater", "nutrients"]
	var many: Array = presets.duplicate()
	for i in 200:
		var a: String = kinds[(i * 7) % kinds.size()]
		var b: String = kinds[(i * 11 + 3) % kinds.size()]
		var c: String = kinds[(i * 13 + 5) % kinds.size()]
		many.append(_p("P%03d" % i, [[a, 1.0]], [[b, 0.6], [c, 0.3]], float(i % 50)))
	var big := LoopPlanner.build_library(many, [], true)
	var t0 := Time.get_ticks_usec()
	LoopPlanner.plan(big, "urine", "sink", 1.0, ctx)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	_check("200 presets plus the classes in under 50 ms", ms < 50.0, "%.1f ms" % ms)
	var src := LoopPlanner.plan(lib, "irrigation_water", "source", 3.0, {"used": {}, "made": {},
		"stocked": {"liquid_fertilizer": true}, "sinks": {}})
	_check("source side: irrigation water from a stored kind", not src.is_empty() and bool(src[0]["complete"]),
		str(src.slice(0, 1)))


func _test_real_library() -> void:
	var lib := LoopPlanner.library()
	_check("the game's library has edges for presets, recipes and classes",
		(lib["edges"] as Array).size() > 50)
	var ctx := {"used": {"water": true, "food": true}, "made": {}, "stocked": {}, "sinks": {}}
	var ur := LoopPlanner.plan(lib, "urine", "sink", 0.5, ctx)
	var found := false
	for pl in ur:
		if _labels(pl).has("Urine Nutrient Recovery") and (pl["steps"] as Array).size() <= 2:
			found = true
	_check("urine → water + nutrients in 1–2 steps with Urine Nutrient Recovery", found,
		str(ur.map(func(x): return _labels(x))))
	var fw_lib := LoopPlanner.build_library([], [], true)
	var fw := LoopPlanner.plan(fw_lib, "food_waste", "sink", 1.0, ctx)
	var classes := false
	for pl2 in fw:
		for st in pl2["steps"]:
			if str(st["type"]) == "class":
				classes = true
	_check("with no machine, a class closes food scraps", classes)
	var imp := false
	for k in ["water", "food"]:
		for pl3 in LoopPlanner.plan(lib, k, "source", 1.0, {"used": {}, "made": {}, "stocked": {}, "sinks": {}}):
			for st3 in pl3["steps"]:
				var pre := ComponentPresets.find_preset_by_label(str(st3["label"]))
				if str((pre.get("specs", {}) as Dictionary).get("role", "")) == "import":
					imp = true
	_check("a delivery (water truck, food brought in) is never a plan", not imp)
	var gw := LoopPlanner.plan(lib, "greywater", "sink", 10.0, ctx)
	_check("greywater: the best plan uses a machine, not a class", not gw.is_empty()
		and str(gw[0]["steps"][0]["type"]) == "preset", str(gw.slice(0, 1).map(func(x): return _labels(x))))


func _test_scope() -> void:
	var m := GraphModel.new()
	m.add_item({"id": "hab", "type": "processor", "specs": {"role": "habitat", "occupants": 4.0,
		"inputs": [{"kind": "water", "rate": 2.0}], "outputs": [{"kind": "greywater", "rate": 1.6}, {"kind": "urine", "rate": 0.06}]}})
	m.add_item({"id": "tank", "type": "resource", "specs": {"resource_kind": "water", "capacity_qty": 1000.0, "level": 0.5}})
	var fo := LoopPlanner.find_open(m, "root")
	var by: Dictionary = {}
	for o in fo["open"]:
		by[str(o["kind"]) + ":" + str(o["side"])] = o
	_check("open: the camp's greywater and urine are sinks", by.has("greywater:sink") and by.has("urine:sink"))
	_check("open: the water it drinks is a source", by.has("water:source")
		and absf(float(by["water:source"]["kg_h"]) - 8.0 * CompositionCatalog.kg_per_unit("water")) < 0.01)
	var m2 := GraphModel.new()
	m2.add_item({"id": "hab", "type": "processor", "specs": {"role": "habitat", "occupants": 4.0,
		"inputs": [{"kind": "meal", "rate": 0.0}], "outputs": []}})
	m2.add_item({"id": "kit", "type": "processor", "specs": {"inputs": [], "outputs": [{"kind": "meal", "rate": 8.0}]}})
	var meal_open := false
	for o2 in LoopPlanner.find_open(m2, "root")["open"]:
		if str(o2["kind"]) == "meal":
			meal_open = true
	_check("meals the people eat at a rate their sim sets are not left over", not meal_open)
	_check("urine outranks greywater per kg (its N)", LoopPlanner.value_per_kg("urine") > LoopPlanner.value_per_kg("greywater"))
	var sp := LoopPlanner.plan_scope(m, "root", 6)
	var gw_plans: Array = []
	for row in sp:
		if str(row["open"]["kind"]) == "greywater":
			gw_plans = row["plans"]
	_check("plan_scope plans the greywater", not gw_plans.is_empty())
	var closes_water := false
	for pl in gw_plans:
		for st in pl["steps"]:
			for g in st["gives"]:
				if LoopPlanner.WATER_KINDS.has(str(g)):
					closes_water = true
	_check("… back into water the camp drinks", closes_water)
