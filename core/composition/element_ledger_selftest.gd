extends SceneTree

## ElementLedger (resource composition plan Phase 2), offline:
##   Godot --headless --path . --script core/composition/element_ledger_selftest.gd
## (--import first). A small graph built in code with the wire rates set by
## hand, as the flow engine stamps them: a person on drinking water making
## greywater and urine, a urine still winning clean water back, a compost bin
## that makes nitrogen from nothing, a delivery, a roof catchment, an
## unlimited supply tank, a tank of unknown make-up, a full store still
## filling and an output with nowhere to go. Pins the stocks (usable vs
## bound water, N in store), the boundary sides, the water recovery ratio by
## hand, the unaccounted list, the leaks, and the dashboard rows.
## Carries EXPECTED_CHECKS.

const EXPECTED_CHECKS := 30

var _checks := 0
var _fails := 0
var _m: GraphModel


func _check(name: String, cond: bool, detail: String = "") -> void:
	_checks += 1
	if not cond:
		_fails += 1
		print("  FAIL ", name, ("  (" + detail + ")") if not detail.is_empty() else "")


static func _near(a: float, b: float, tol: float) -> bool:
	return absf(a - b) <= tol


func _tank(id: String, kind: String, cap: float, level: float, extra: Dictionary = {}) -> void:
	var specs := {"name": id, "resource_kind": kind, "capacity_qty": cap, "level": level}
	specs.merge(extra)
	_m.add_item({"id": id, "type": "resource", "specs": specs})


func _proc(id: String, extra: Dictionary = {}) -> void:
	var specs := {"name": id}
	specs.merge(extra)
	_m.add_item({"id": id, "type": "processor", "specs": specs})


func _wire(src: String, tgt: String, kind: String, rate: float) -> void:
	var c := {"source_item_id": src, "source_handle_id": "res_out_0", "target_item_id": tgt,
		"target_handle_id": "res_in_0", "polarity": "resource", "resource_type": kind}
	_m.add_connection(c)
	c["flow_rate"] = rate


func _initialize() -> void:
	_m = GraphModel.new()
	_tank("drink", "water", 1000.0, 0.5)
	_tank("grey", "greywater", 500.0, 0.2)
	_tank("pee", "urine", 100.0, 0.5)
	_tank("irr", "irrigation_water", 200.0, 0.1)
	_tank("brine", "brine", 20.0, 0.0)
	_tank("supply", "water", 100.0, 0.5, {"unlimited_capacity": true})
	_tank("mystery", "no_such_slurry_xyz", 50.0, 0.4)
	_tank("compost_out", "nutrients", 10.0, 1.0)
	_tank("wood", "biomass", 500.0, 0.2)
	_proc("person", {"role": "habitat"})
	_proc("still", {"output_unconnected_kinds": ["brine", "electric"]})
	_proc("compost")
	_proc("truck")
	# A machine whose optional cooling-water output is left unwired: it runs
	# and drains the stream off site.
	_proc("cooler", {"inputs": [{"kind": "water", "rate": 1.0}],
		"outputs": [{"kind": "hot_water", "rate": 1.0, "optional": true}],
		"output_unconnected_kinds": ["hot_water"]})
	_m.add_item({"id": "roof", "type": "catchment", "specs": {"name": "roof"}})
	_wire("drink", "person", "water", 2.0)
	_wire("person", "grey", "greywater", 1.6)
	_wire("person", "pee", "urine", 0.05)
	_wire("pee", "still", "urine", 0.05)
	_wire("still", "irr", "irrigation_water", 0.0475)
	_wire("wood", "compost", "biomass", 1.0)
	_wire("compost", "compost_out", "nutrients", 0.5)
	_wire("truck", "drink", "water", 10.0)
	_wire("roof", "drink", "water", 4.0)
	_wire("supply", "person", "water", 0.0)
	_wire("drink", "cooler", "water", 0.5)

	var led := ElementLedger.compute(_m, "root")
	var st: Dictionary = led["stock"]
	# Stocks: usable = drinking 500 L + irrigation 20 L (clean water kinds);
	# bound = greywater 100 L + urine 50 L, by their water fractions.
	var usable_expect := 500.0 * 1.0 * CompositionCatalog.water_fraction("water") \
		+ 20.0 * 1.0 * CompositionCatalog.water_fraction("irrigation_water")
	_check("usable water = drinking + irrigation stores", _near(float(st["usable_water_kg"]), usable_expect, 0.01),
		"%.3f vs %.3f" % [float(st["usable_water_kg"]), usable_expect])
	var bound_expect := 100.0 * CompositionCatalog.water_fraction("greywater") \
		+ 50.0 * 1.02 * CompositionCatalog.water_fraction("urine") \
		+ 100.0 * CompositionCatalog.water_fraction("biomass")
	_check("bound water = greywater + urine + wood moisture", _near(float(st["bound_water_kg"]), bound_expect, 0.01),
		"%.3f vs %.3f" % [float(st["bound_water_kg"]), bound_expect])
	_check("bound water is listed by kind", (st["bound_by_kind"] as Dictionary).has("urine"))
	var n_expect := 50.0 * 1.02 * float(CompositionCatalog.elements_of("urine")["N"]) \
		+ 10.0 * float(CompositionCatalog.elements_of("nutrients")["N"]) \
		+ 100.0 * float(CompositionCatalog.elements_of("biomass").get("N", 0.0)) \
		+ 100.0 * float(CompositionCatalog.elements_of("greywater").get("N", 0.0)) \
		+ 20.0 * float(CompositionCatalog.elements_of("irrigation_water").get("N", 0.0))
	_check("stored N sums every store", _near(float((st["elements"] as Dictionary).get("N", 0.0)), n_expect, 1e-4),
		"%.4f vs %.4f" % [float((st["elements"] as Dictionary).get("N", 0.0)), n_expect])
	_check("plant matter counts as stored energy", _near(float(st["energy_mj"]), 100.0 * CompositionCatalog.lhv_mj_per_kg("biomass"), 0.5))
	_check("the unlimited supply is not stock", int(st["unlimited"]) == 1)
	_check("a store of unknown make-up is counted apart", (led["unknown"] as Array).size() == 1
		and str((led["unknown"] as Array)[0]["kind"]) == "no_such_slurry_xyz")
	_check("… and is not in the stores", (led["stores"] as Array).size() == 7, "%d" % (led["stores"] as Array).size())

	# Boundary: rain from the roof, the truck as an import (no material in).
	var b: Dictionary = led["boundary"]
	_check("rain side is the catchment's 4 L/h", _near(float((b["rain"] as Dictionary)["kg_h"]), 4.0, 1e-6))
	_check("the truck's 10 L/h is an import", _near(float((b["imports"] as Dictionary)["kg_h"]), 10.0, 1e-6))
	_check("a zero-rate wire adds nothing", _near(float((b["imports"] as Dictionary)["water_kg_h"]),
		10.0 * CompositionCatalog.water_fraction("water"), 1e-6))
	_check("nothing crosses root's edge", _near(float((b["in"] as Dictionary)["kg_h"]), 0.0, 1e-9)
		and _near(float((b["out"] as Dictionary)["kg_h"]), 0.0, 1e-9))

	# Water recovery by hand: the person's waste water counts as used (all
	# its intake was clean); the still's irrigation water counts as recovered
	# (all its intake was urine).
	var used := 1.6 * CompositionCatalog.water_fraction("greywater") + 0.05 * 1.02 * CompositionCatalog.water_fraction("urine")
	var rec := 0.0475 * CompositionCatalog.water_fraction("irrigation_water")
	var w: Dictionary = led["water"]
	_check("used water by hand", _near(float(w["used_kg_h"]), used, 1e-6), "%.5f vs %.5f" % [float(w["used_kg_h"]), used])
	_check("recovered water by hand", _near(float(w["recovered_kg_h"]), rec, 1e-6))
	_check("recovery ratio = recovered / used", _near(float(w["ratio"]), rec / used, 1e-6), "%.4f" % float(w["ratio"]))

	# Unaccounted: the compost bin makes N from wood that has almost none;
	# the still loses its brine (no wire) — urine's salts and N vanish.
	var unacc: Array = led["unaccounted"]
	var by_id: Dictionary = {}
	for u in unacc:
		by_id[str(u["id"])] = u
	_check("compost makes N from nothing", by_id.has("compost")
		and float((by_id["compost"]["deltas"] as Dictionary).get("N", 0.0)) > 0.3)
	_check("the still loses N (its brine has no wire)", by_id.has("still")
		and float((by_id["still"]["deltas"] as Dictionary).get("N", 0.0)) < 0.0)
	var person: Dictionary = (led["nodes"] as Dictionary).get("person", {})
	_check("the person breathes: water vapour leaves by the air side",
		float((person.get("air", {}) as Dictionary).get("H2O", 0.0)) > 0.0, str(person.get("air", {})))
	_check("the cooler drains its unwired cooling water (half its listed rate)",
		_near(float((led["dumped"] as Dictionary)["kg_h"]), 0.5 * CompositionCatalog.kg_per_unit("hot_water"), 1e-6),
		"%.4f" % float((led["dumped"] as Dictionary)["kg_h"]))
	_check("… and so is not unaccounted", not by_id.has("cooler"))
	_check("the scope gives water vapour to the air", float(((led["air"] as Dictionary)["out"] as Dictionary)["kg_h"]) > 0.0
		and float(((led["air"] as Dictionary)["gases"] as Dictionary).get("H2O", 0.0)) > 0.0)
	_check("the worst is listed first", unacc.size() >= 2 and float(unacc[0]["score"]) >= float(unacc[1]["score"]))
	var txt := ElementLedger.unaccounted_text(by_id.get("compost", {}))
	_check("the words say so", txt.find("from nothing") >= 0 and txt.find("nitrogen") >= 0, txt)

	# Leaks: the still's brine output (electric is not material), and the
	# full nutrients store still taking the compost's flow.
	var lk: Array = led["leaks"]
	var whats: Array = []
	for l in lk:
		whats.append("%s:%s:%s" % [l["id"], l["what"], ",".join(l["kinds"])])
	_check("an output with nowhere to go is a leak (material only)", whats.has("still:nowhere_to_go:brine"), str(whats))
	_check("a full store still filling is a leak", whats.has("compost_out:full:nutrients"), str(whats))

	var rows := ElementLedger.rows(led)
	var keys: Array = []
	for r in rows:
		keys.append(str((r as Dictionary).get("k", (r as Dictionary).get("text", ""))))
	_check("rows: water, recovery, nutrients, doesn't-add-up, lost", keys.has("Usable water stored")
		and keys.has("Water recovery") and keys.has("Nitrogen") and keys.has("Doesn't add up") and keys.has("Lost"), str(keys))
	_check("rows: the air and what is drained off site", keys.has("Air") and keys.has("Drained off site"), str(keys))
	_check("mass words: 0.5 kg → 500 g, 1500 kg → 1.50 t", ElementLedger.fmt_kg(0.5) == "500 g"
		and ElementLedger.fmt_kg(1500.0) == "1.50 t", "%s %s" % [ElementLedger.fmt_kg(0.5), ElementLedger.fmt_kg(1500.0)])
	var empty := ElementLedger.rows(ElementLedger.compute(GraphModel.new(), "root"))
	_check("an empty graph gives no rows", empty.is_empty())
	var none := ElementLedger.compute(null)
	_check("a null model is safe", is_nan(float((none["water"] as Dictionary)["ratio"])))

	if _checks != EXPECTED_CHECKS:
		_fails += 1
		push_error("FAIL: check count drifted — expected %d, ran %d (a runtime error aborted a test function?)" % [EXPECTED_CHECKS, _checks])
	if _fails == 0:
		print("ELEMENT LEDGER SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("ELEMENT LEDGER SELFTEST FAIL  (%d of %d checks failed)" % [_fails, _checks])
	quit(0 if _fails == 0 else 1)
