extends SceneTree

## The element lens, ElementHistory and the cycle Sankey (resource
## composition plan Phase 4). Offline:
##   Godot --headless --path . --script core/composition/element_cycles_selftest.gd
## Carries EXPECTED_CHECKS.

const EXPECTED_CHECKS := 28

var _checks := 0
var _fails := 0
var _m: GraphModel


func _check(name: String, cond: bool, detail: String = "") -> void:
	_checks += 1
	if cond:
		print("  ok   ", name)
	else:
		_fails += 1
		print("  FAIL ", name, ("  (" + detail + ")") if not detail.is_empty() else "")


func _near(a: float, b: float, tol: float) -> bool:
	return absf(a - b) <= tol


func _tank(id: String, kind: String, cap: float, level: float) -> void:
	_m.add_item({"id": id, "type": "resource", "specs": {"name": id, "resource_kind": kind,
		"capacity_qty": cap, "level": level}})


func _wire(src: String, tgt: String, kind: String, rate: float) -> void:
	var c := {"source_item_id": src, "source_handle_id": "res_out_0", "target_item_id": tgt,
		"target_handle_id": "res_in_0", "polarity": "resource", "resource_type": kind}
	_m.add_connection(c)
	c["flow_rate"] = rate


func _initialize() -> void:
	_test_lens()
	_m = GraphModel.new()
	_tank("drink", "water", 1000.0, 0.5)
	_tank("pantry", "food", 100.0, 0.5)
	_tank("grey", "greywater", 500.0, 0.1)
	_tank("pee", "urine", 100.0, 0.1)
	_m.add_item({"id": "person", "type": "processor", "specs": {"name": "person", "role": "habitat"}})
	_wire("drink", "person", "water", 2.0)
	_wire("pantry", "person", "food", 0.05)
	_wire("person", "grey", "greywater", 1.6)
	_wire("person", "pee", "urine", 0.06)
	var led := ElementLedger.compute(_m, "root")
	_check("the ledger lists its material wires as edges", (led["edges"] as Array).size() == 4,
		"%d" % (led["edges"] as Array).size())
	_test_history(led)
	_test_sankey(led)
	_test_tracks()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		push_error("FAIL: check count drifted — expected %d, ran %d (a runtime error aborted a test function?)" % [EXPECTED_CHECKS, _checks])
	if _fails == 0:
		print("ELEMENT CYCLES SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("ELEMENT CYCLES SELFTEST FAIL  (%d of %d checks failed)" % [_fails, _checks])
	quit(0 if _fails == 0 else 1)


func _test_lens() -> void:
	var urine_n := ElementLens.amount_of("urine", 1.0, "N")
	_check("lens N of 1 L urine = its N per kg × 1.02 kg", _near(urine_n,
		float(CompositionCatalog.elements_of("urine")["N"]) * CompositionCatalog.kg_per_unit("urine"), 1e-9),
		"%.6f" % urine_n)
	_check("lens water of 1 L water ≈ 1 kg", _near(ElementLens.amount_of("water", 1.0, "water"), 1.0, 0.01))
	_check("lens energy of 1 kg biomass = its LHV", _near(ElementLens.amount_of("biomass", 1.0, "energy"),
		CompositionCatalog.lhv_mj_per_kg("biomass"), 0.05))
	_check("electricity carries no element", ElementLens.amount_of("electric", 5.0, "C") == 0.0)
	_check("rate words: 0.25 kg N/h", ElementLens.fmt_rate(0.25, "N") == "250 g N/h",
		ElementLens.fmt_rate(0.25, "N"))
	_check("energy per hour reads as power", ElementLens.fmt_rate(3.6, "energy").ends_with("kW"),
		ElementLens.fmt_rate(3.6, "energy"))
	_check("width grows with flux, never past the max", ElementLens.width_for(0.1, 1.0) < ElementLens.width_for(0.5, 1.0)
		and _near(ElementLens.width_for(1.0, 1.0), ElementLens.WIDTH_MAX, 1e-6)
		and ElementLens.width_for(0.0, 1.0) == 0.0)


func _test_history(led: Dictionary) -> void:
	var water_rate := ElementLens.amount_of("water", 2.0, "water")
	var key := "drink>person|water"
	var h := ElementHistory.new()
	h.record(100.0, led)
	h.record(101.5, led)
	h.record(102.0, led)
	var w := h.window(100.0, 102.0)
	_check("two sim hours counted", _near(float(w["hours"]), 2.0, 1e-9), "%.4f" % float(w["hours"]))
	var wv: PackedFloat64Array = (w["edges"] as Dictionary).get(key, PackedFloat64Array())
	_check("an edge's water over two hours = rate × 2", wv.size() == ElementLens.SIZE
		and _near(wv[int(ElementLens.INDEX["water"])], water_rate * 2.0, 1e-6))
	_check("the window splits across hour bins", h.bin_count() == 2, "%d" % h.bin_count())
	h.record(101.0, led)
	var w2 := h.window(100.0, 102.0)
	_check("a scrub back drops what came after", _near(float(w2["hours"]), 1.0, 1e-9), "%.4f" % float(w2["hours"]))
	h.record(120.0, led)
	_check("a jump of more than 6 h counts nothing", _near(float(h.window(100.0, 130.0)["hours"]), 1.0, 1e-9))
	var person_air: Dictionary = w["node_air_out"]
	_check("the person's breath is booked to the air", person_air.has("person")
		and (person_air["person"] as PackedFloat64Array)[int(ElementLens.INDEX["water"])] > 0.0)
	var now := ElementHistory.from_ledger(led)
	_check("NOW is one hour of the rates", _near(float(now["hours"]), 1.0, 1e-9)
		and _near(float((now["edges"][key] as PackedFloat64Array)[int(ElementLens.INDEX["water"])]), water_rate, 1e-6))
	var ser: Array = h.recovery_series()
	_check("recovery series: one point per bin with used water", (ser[0] as PackedFloat64Array).size() == 1
		and float((ser[1] as PackedFloat32Array)[0]) == 0.0)
	_check("names come from the ledger", str(h.names.get("person", "")) == "person"
		and str(h.names.get("drink", "")) == "drink")


func _test_sankey(led: Dictionary) -> void:
	var now := ElementHistory.from_ledger(led)
	var sk := ElementSankey.build(now, "N", led["nodes"], {"person": "The camp", "pantry": "Pantry"})
	var by_id: Dictionary = {}
	for n in sk["nodes"]:
		by_id[str(n["id"])] = n
	_check("the person is in the middle", by_id.has("M:person") and int(by_id["M:person"]["col"]) == 1)
	_check("the pantry feeds them (left)", by_id.has("L:pantry") and str(by_id["L:pantry"]["label"]) == "Pantry")
	_check("their urine goes right", by_id.has("R:pee"))
	var nin := 0.0
	var nout := 0.0
	for l in sk["links"]:
		if str(l["b"]) == "M:person":
			nin += float(l["value"])
		if str(l["a"]) == "M:person":
			nout += float(l["value"])
	_check("N entering the person shows on the left", nin > 0.0, "%.5f" % nin)
	_check("water's Sankey sends breath to the air", _has_link(ElementSankey.build(now, "water",
		led["nodes"], {}), "M:person", "R:air"))
	var sk_c := ElementSankey.build(now, "C", led["nodes"], {})
	_check("the carbon the person breathes out goes to the air", _has_link(sk_c, "M:person", "R:air"))
	_check("links are biggest first", (sk["links"] as Array).size() < 2
		or float(sk["links"][0]["value"]) >= float(sk["links"][1]["value"]))


func _has_link(sk: Dictionary, a: String, b: String) -> bool:
	for l in sk["links"]:
		if str(l["a"]) == a and str(l["b"]) == b and float(l["value"]) > 0.0:
			return true
	return false


func _test_tracks() -> void:
	var items: Array = [
		{"id": "a", "type": "resource", "specs": {"resource_kind": "water", "capacity_qty": 100.0}},
		{"id": "b", "type": "resource", "specs": {"resource_kind": "urine", "capacity_qty": 10.0}},
		{"id": "c", "type": "resource", "specs": {"resource_kind": "water", "capacity_qty": 1.0, "unlimited_capacity": true}},
	]
	var usable := TimelineCompositionChannels.stock_terms(items, "water_usable")
	var bound := TimelineCompositionChannels.stock_terms(items, "water_bound")
	_check("usable water counts clean stores only, never an unlimited supply", usable.size() == 1
		and str(usable[0]["id"]) == "a", str(usable))
	_check("bound water counts the urine store", bound.size() == 1 and str(bound[0]["id"]) == "b")
	var lv := func(id: String, _t: float) -> float: return 0.5 if id == "a" else NAN
	var bins := TimelineCompositionChannels.stock_bins(usable, lv, 1.0, 100, 4)
	_check("a stock bin = level × capacity × its make-up", _near(float((bins["mean"] as PackedFloat32Array)[0]),
		50.0 * CompositionCatalog.water_fraction("water") * CompositionCatalog.kg_per_unit("water"), 0.01),
		"%.3f" % float((bins["mean"] as PackedFloat32Array)[0]))
	var ser := [PackedFloat64Array([100.0, 101.0]), PackedFloat32Array([0.25, 0.5])]
	var rb := TimelineCompositionChannels.recovery_bins(ser, 1.0, 100, 2, 102.0)
	_check("recovery reads in % per bin", _near(float((rb["mean"] as PackedFloat32Array)[0]), 25.0, 1e-4)
		and _near(float((rb["mean"] as PackedFloat32Array)[1]), 50.0, 1e-4))
