extends SceneTree

## Headless self-test for THE CALCULATOR and the loop challenge it sets:
## CampFlowMeter (mass-exact integration at any step size, a scrub back
## truncates, a jump is not metered, per-day / per-person figures, the pee and
## poo inside the blackwater, off-site imports, the dict round trip) and
## CampLoopClosure over a real CampTemplates camp on a GraphModel (an open
## camp scores 0, the worst loop is suggested with the presets that close
## it, `apply` drops a Greywater Filter wired to the camp's own tanks and the
## greywater loop closes). Offline. Carries EXPECTED_CHECKS; --import first.
##   godot --headless --path . --script core/population/camp_flow_meter_selftest.gd

const EXPECTED_CHECKS := 18
const GraphModelScript := preload("res://system_graph/data/graph_model.gd")

var _failures := 0
var _checks := 0


func _init() -> void:
	_test_meter()
	_test_closure()
	if _checks != EXPECTED_CHECKS:
		_failures += 1
		print("  FAIL: ran %d checks, expected %d (a test function aborted?)" % [_checks, EXPECTED_CHECKS])
	if _failures == 0:
		print("CAMP FLOW METER SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("CAMP FLOW METER SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


func _run(step_h: float, hours: float, t0: float = 17_000_000.0) -> CampFlowMeter:
	var m := CampFlowMeter.new()
	var t := t0
	m.record(t, {}, {}, 0.0)
	while t < t0 + hours - 1e-9:
		t += step_h
		# 10 people: 50 L water, 1.5 kg food a person a day; 4 L/h of it
		# from off site.
		m.record(t, {"water": 10.0 * 50.0 / 24.0, "food": 10.0 * 1.5 / 24.0},
			{"greywater": 10.0 * 40.0 / 24.0, "blackwater": 10.0 * 10.0 / 24.0}, 10.0,
			{"water": 4.0}, {})
	return m


func _test_meter() -> void:
	var a := _run(0.05, 48.0)
	var b := _run(0.5, 48.0)
	_check("meter: two days of water = 1000 L", absf(a.total("in:water") - 1000.0) < 0.5,
		"%.2f" % a.total("in:water"))
	_check("meter: the step size does not change the total", absf(a.total("in:water") - b.total("in:water")) < 0.5)
	_check("meter: per day = 500 L", absf(a.per_day("in:water") - 500.0) < 1.0, "%.2f" % a.per_day("in:water"))
	_check("meter: person-days = 20", absf(a.person_days() - 20.0) < 0.05)
	_check("meter: imported water metered apart", absf(a.total("imp:water") - 192.0) < 0.5)
	var rows := a.summary()
	var by: Dictionary = {}
	for r in rows:
		by[str((r as Dictionary)["key"])] = r
	_check("meter: per person per day = 50 L", absf(float((by["in:water"] as Dictionary)["per_person_day"]) - 50.0) < 0.2)
	_check("meter: pee per person per day (Rose 2015)",
		absf(float((by["pee"] as Dictionary)["per_person_day"]) - CampFlowMeter.URINE_L_PER_PERSON_DAY) < 1e-6)
	_check("meter: poo so far = person-days x 0.128 kg", absf(float((by["poo"] as Dictionary)["total"]) - 20.0 * 0.128) < 0.02)
	var t_mid := 17_000_000.0 + 24.0
	a.record(t_mid, {}, {}, 0.0)
	_check("meter: a scrub back truncates to the playhead", absf(a.total("in:water") - 500.0) < 21.0,
		"%.2f" % a.total("in:water"))
	var c := CampFlowMeter.new()
	c.record(100.0, {}, {}, 0.0)
	c.record(120.0, {"water": 10.0}, {}, 1.0)
	_check("meter: a 20 h jump is not metered", c.total("in:water") == 0.0)
	var d := CampFlowMeter.from_dict(b.to_dict())
	_check("meter: the dict round trip keeps every total", absf(d.total("out:blackwater") - b.total("out:blackwater")) < 1e-6
		and absf(d.total("imp:water") - b.total("imp:water")) < 1e-6)


func _stamp(model, n: int) -> String:
	var def := CampTemplates.definition("mixed", n)
	model.put_definition(def)
	var cid: String = GraphComponentDefs.realize(model, str(def["id"]), "root", Vector2.ZERO,
		{"camp_lot_id": "camp:camp_1", "camp_headcount": n, "name": "Camp One"})
	GraphComponentDefs.make_unique(model, cid)
	return cid


func _test_closure() -> void:
	var model = GraphModelScript.new()
	var cid := _stamp(model, 12)
	var sc := CampLoopClosure.score(model, cid)
	_check("closure: a fresh camp scores 0", float(sc["score"]) == 0.0, str(sc))
	_check("closure: it needs water and makes greywater", (sc["need"] as Dictionary).has("water")
		and (sc["need"] as Dictionary).has("greywater"))
	var sugg := CampLoopClosure.suggest(model, cid)
	_check("closure: every open loop is suggested", sugg.size() >= 3)
	var iid := CampLoopClosure.apply(model, cid, "Greywater Filter")
	var scope := str(model.get_item(cid).get("child_scope_id", ""))
	_check("closure: the filter lands inside the camp", not iid.is_empty()
		and str(model.get_item(iid).get("scope_id", "")) == scope)
	var wired_in := false
	var wired_out := false
	for c in model.get_connections_in_scope(scope):
		var cd: Dictionary = c
		if str(cd.get("target", "")) == iid and str(cd.get("resource_type", "")) == "greywater":
			wired_in = true
		if str(cd.get("source", "")) == iid and str(cd.get("resource_type", "")) == "water":
			wired_out = true
	_check("closure: wired from the grey tank and into the water tank", wired_in and wired_out)
	var sc2 := CampLoopClosure.score(model, cid)
	_check("closure: greywater is closed now", float((sc2["kinds"] as Dictionary).get("greywater", 0.0)) >= 0.999,
		str(sc2["kinds"]))
	_check("closure: and water partly", float((sc2["kinds"] as Dictionary).get("water", 0.0)) > 0.0)
