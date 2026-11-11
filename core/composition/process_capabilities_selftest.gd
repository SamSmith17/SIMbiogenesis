extends SceneTree

## Unit-operation classes and "what can separate this?" (resource
## composition plan Phase 5). Offline:
##   Godot --headless --path . --script core/composition/process_capabilities_selftest.gd
## Carries EXPECTED_CHECKS.

const EXPECTED_CHECKS := 20

var _checks := 0
var _fails := 0


func _check(name: String, cond: bool, detail: String = "") -> void:
	_checks += 1
	if cond:
		print("  ok   ", name)
	else:
		_fails += 1
		print("  FAIL ", name, ("  (" + detail + ")") if not detail.is_empty() else "")


func _initialize() -> void:
	_test_classes()
	_test_transfers()
	_test_separate()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		push_error("FAIL: check count drifted — expected %d, ran %d (a runtime error aborted a test function?)" % [EXPECTED_CHECKS, _checks])
	if _fails == 0:
		print("PROCESS CAPABILITIES SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("PROCESS CAPABILITIES SELFTEST FAIL  (%d of %d checks failed)" % [_fails, _checks])
	quit(0 if _fails == 0 else 1)


func _test_classes() -> void:
	# Every class tag a preset carries is a class the table knows.
	var unknown: PackedStringArray = []
	for p in ProcessCapabilities._library_presets():
		for t in ((p as Dictionary).get("specs", {}) as Dictionary).get("unit_ops", []):
			if not UnitOps.has(str(t)) and not unknown.has(str(t)):
				unknown.append(str(t))
	_check("every preset's unit_ops tag is a known class", unknown.is_empty(), ", ".join(unknown))
	var bad: PackedStringArray = []
	for id in UnitOps.CLASSES.keys():
		var row: Dictionary = UnitOps.CLASSES[id]
		for g in row.get("gives", []):
			var r := float((g as Dictionary)["recovery"])
			var to := str((g as Dictionary)["to"])
			if r <= 0.0 or r > 1.0 or (to != "air" and not CompositionCatalog.is_known(to)):
				bad.append("%s→%s" % [id, to])
		if not (row.get("gives", []) as Array).is_empty() and str(row.get("src", "")).is_empty():
			bad.append("%s has no source" % id)
	_check("every class gives a known kind at a recovery in (0, 1], with a source", bad.is_empty(), ", ".join(bad))
	var d: Dictionary = UnitOps.CLASSES["distillation"]
	_check("distillation's floor is the latent heat (0.627 kWh/kg)", absf(float(d["kwh_min"]) - 0.627) < 0.001
		and float(d["kwh_per_kg"]) >= float(d["kwh_min"]))
	_check("RO's floor is the seawater minimum work (1.06 kWh/m³)",
		absf(float(UnitOps.CLASSES["reverse_osmosis"]["kwh_min"]) - 0.00106) < 1e-6)
	_check("urine is taken by distillation, VCD, struvite and nitrification", UnitOps.accepts("distillation", "urine")
		and UnitOps.accepts("vapour_compression_distillation", "urine")
		and UnitOps.accepts("struvite_precipitation", "urine") and UnitOps.accepts("nitrification", "urine"))
	_check("seawater is distillable by its family", UnitOps.accepts("distillation", "seawater")
		and not UnitOps.accepts("composting", "seawater"))


func _test_transfers() -> void:
	var tr := ProcessCapabilities.transfers_of("still", "preset",
		[{"kind": "seawater", "rate": 1.0}], [{"kind": "distilled_water", "rate": 0.9}, {"kind": "brine", "rate": 0.09}],
		"", 0.8, ["distillation"])
	var water: Dictionary = {}
	for t in tr:
		if str(t["target"]) == "water" and str(t["to"]) == "distilled_water":
			water = t
	_check("a still moves seawater's water into distilled water", not water.is_empty())
	_check("… recovering about 0.9 / 0.965 of it", absf(float(water.get("recovery", 0.0))
		- 0.9 / CompositionCatalog.water_fraction("seawater") / CompositionCatalog.kg_per_unit("seawater")) < 0.01,
		"%.3f" % float(water.get("recovery", 0.0)))
	_check("… at the listed power over the feed", absf(float(water.get("kwh_per_kg", 0.0))
		- 0.8 / CompositionCatalog.kg_per_unit("seawater")) < 1e-6)
	_check("its classes ride along", (water.get("classes", []) as Array).has("distillation"))
	var none := ProcessCapabilities.transfers_of("pump", "preset", [], [{"kind": "water", "rate": 1.0}], "", 0.5, [])
	_check("a machine with no material in transfers nothing", none.is_empty())
	var idx := ProcessCapabilities.index()
	_check("the library index has hundreds of transfers", idx.size() > 100, "%d" % idx.size())
	var t0 := Time.get_ticks_usec()
	ProcessCapabilities.index()
	_check("a second index() is the cache (under 5 ms)", (Time.get_ticks_usec() - t0) < 5000,
		"%d µs" % (Time.get_ticks_usec() - t0))


func _test_separate() -> void:
	var u := ProcessCapabilities.separate("urine")
	var by_t: Dictionary = {}
	for t in u["targets"]:
		by_t[str(t["target"])] = t
	_check("urine offers water and nitrogen", by_t.has("water") and by_t.has("N"))
	var water_opts: Array = by_t.get("water", {}).get("options", [])
	var has_unr := false
	for o in water_opts:
		if str(o["label"]) == "Urine Nutrient Recovery":
			has_unr = true
	_check("Urine Nutrient Recovery is a way to get water out of urine", has_unr)
	var n_opts: Array = by_t.get("N", {}).get("options", [])
	var n_to_nutrients := false
	for o2 in n_opts:
		if str(o2["to"]) == "nutrients" and str(o2["type"]) != "class":
			n_to_nutrients = true
	_check("… and a preset puts its nitrogen into nutrients", n_to_nutrients)
	var sorted_ok := true
	for i in range(1, water_opts.size()):
		if float(water_opts[i]["recovery"]) > float(water_opts[i - 1]["recovery"]) + 0.021:
			sorted_ok = false
	_check("options are ranked by recovery", sorted_ok)
	var fw := ProcessCapabilities.separate("food_waste")
	var drying := false
	for t2 in fw["targets"]:
		if str(t2["target"]) == "water":
			for o3 in t2["options"]:
				if str(o3["type"]) == "class" and str(o3.get("class", "")) == "drying":
					drying = true
	_check("food scraps' water: the drying class answers", drying)
	_check("the same question twice gives the same answer",
		JSON.stringify(ProcessCapabilities.separate("urine")) == JSON.stringify(u))
	_check("a kind with no make-up gives nothing", (ProcessCapabilities.separate("no_such_kind_xyz")["targets"] as Array).is_empty())
