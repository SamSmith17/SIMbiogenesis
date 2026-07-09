extends SceneTree

## Headless self-test for ClosureMetrics + HighScoreStore.
## Run:
##   Godot.exe.exe --headless --path . --script system_graph/closure_metrics_selftest.gd

const ClosureMetricsScript := preload("res://system_graph/closure_metrics.gd")
const HighScoreStoreScript := preload("res://core/high_score_store.gd")
const GraphModelScript := preload("res://system_graph/data/graph_model.gd")
const ResourceFlowEngineScript := preload("res://system_graph/resource_flow_engine.gd")
const EnergyTimelineScript := preload("res://core/energy_timeline.gd")

var _failures: int = 0
var _checks: int = 0


func _initialize() -> void:
	_test_idle_no_habitat()
	_test_habitat_water_autonomy()
	_test_import_lowers_closure()
	_test_score_formula()
	_test_high_score_store()
	_test_resource_timeline_integrate()
	_test_energy_round_trip_efficiency()
	if _failures == 0:
		print("CLOSURE SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("CLOSURE SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


func _test_idle_no_habitat() -> void:
	var model := GraphModelScript.new()
	var m: Dictionary = ClosureMetricsScript.compute(model, null, null, 100.0)
	var ch: Dictionary = m.get("channels", {}) as Dictionary
	_check("idle energy", str((ch.get("energy", {}) as Dictionary).get("status", "")) == "idle"
			or not bool((ch.get("energy", {}) as Dictionary).get("active", true)))
	_check("idle water", str((ch.get("water", {}) as Dictionary).get("status", "")) == "idle")
	_check("idle food", str((ch.get("food", {}) as Dictionary).get("status", "")) == "idle")


func _test_habitat_water_autonomy() -> void:
	var model := GraphModelScript.new()
	model.add_item({
		"id": "hab", "type": "processor", "x": 0.0, "y": 0.0,
		"specs": {
			"role": "habitat", "occupants": 1, "watts": 0.0, "energy_source": "",
			"inputs": [
				{"kind": "water", "rate": 2.083, "unit": "L/h"},
				{"kind": "food", "rate": 0.0625, "unit": "kg/h"},
			],
			"outputs": [],
		},
	})
	model.add_item({
		"id": "wt", "type": "resource", "x": 0.0, "y": 0.0,
		"specs": {
			"resource_kind": "water", "capacity_qty": 100.0, "capacity_unit": "L",
			"level": 1.0,
		},
	})
	model.add_item({
		"id": "ft", "type": "resource", "x": 0.0, "y": 0.0,
		"specs": {
			"resource_kind": "food", "capacity_qty": 10.0, "capacity_unit": "kg",
			"level": 1.0,
		},
	})
	var m: Dictionary = ClosureMetricsScript.compute(model, null, null, 48.0)
	var water: Dictionary = (m.get("channels", {}) as Dictionary).get("water", {}) as Dictionary
	_check("water active", bool(water.get("active", false)))
	# 100 L / (2.083*24) ≈ 2.0 days
	var days: float = float(water.get("autonomy_days", 0.0))
	_check("water autonomy ~2d", days > 1.8 and days < 2.3, "days=%.3f" % days)
	_check("occupants=1", int(m.get("occupants", 0)) == 1)


func _test_import_lowers_closure() -> void:
	var model := GraphModelScript.new()
	model.add_item({
		"id": "hab", "type": "processor", "x": 0.0, "y": 0.0,
		"specs": {
			"role": "habitat", "occupants": 1, "watts": 0.0, "energy_source": "",
			"inputs": [{"kind": "water", "rate": 2.083, "unit": "L/h"}],
			"outputs": [],
		},
	})
	model.add_item({
		"id": "wt", "type": "resource", "x": 0.0, "y": 0.0,
		"specs": {"resource_kind": "water", "capacity_qty": 200.0, "level": 0.5},
	})
	model.add_item({
		"id": "truck", "type": "processor", "x": 0.0, "y": 0.0,
		"specs": {
			"role": "import", "counts_as_import": true, "import_kind": "water",
			"watts": 0.0, "energy_source": "",
			"outputs": [{"kind": "water", "rate": 50.0, "unit": "L/h"}],
		},
	})
	# Fake tank inflow via ResourceFlowEngine timeline so supply_local can be reduced by import.
	var flow := ResourceFlowEngineScript.new()
	flow.setup(model, null)
	# Seed timeline with inflow that includes import-like rate.
	var tl = flow.get_timeline("wt")
	if tl == null:
		flow.simulate_step_for_test(0.0, 0.0)
		tl = flow.get_timeline("wt")
	if tl != null:
		tl.clear()
		tl.init_anchor(0.0, 0.5)
		# Record 24h of 50 L/h inflow (all from truck) — local supply after import subtract = 0.
		for h in range(1, 25):
			tl.record_step(float(h), 50.0, 50.0, 0.0)
	var m: Dictionary = ClosureMetricsScript.compute(model, flow, null, 24.0)
	var water: Dictionary = (m.get("channels", {}) as Dictionary).get("water", {}) as Dictionary
	_check("import counted", float(water.get("supply_import", 0.0)) > 10.0,
			"import=%.2f" % float(water.get("supply_import", 0.0)))
	_check("import lowers local supply", float(water.get("supply_local", 99.0)) < 1.0,
			"local=%.2f" % float(water.get("supply_local", -1.0)))
	_check("import closure low", float(water.get("closure_pct", 1.0)) < 0.1,
			"closure=%.2f" % float(water.get("closure_pct", -1.0)))


func _test_score_formula() -> void:
	var model := GraphModelScript.new()
	model.add_item({
		"id": "hab", "type": "processor", "x": 0.0, "y": 0.0,
		"specs": {
			"role": "habitat", "occupants": 2, "watts": 0.0, "energy_source": "",
			"inputs": [
				{"kind": "water", "rate": 2.083, "unit": "L/h"},
				{"kind": "food", "rate": 0.0625, "unit": "kg/h"},
			],
			"outputs": [],
		},
	})
	model.add_item({
		"id": "wt", "type": "resource", "x": 0.0, "y": 0.0,
		"specs": {"resource_kind": "water", "capacity_qty": 500.0, "level": 1.0},
	})
	model.add_item({
		"id": "ft", "type": "resource", "x": 0.0, "y": 0.0,
		"specs": {"resource_kind": "food", "capacity_qty": 50.0, "level": 1.0},
	})
	var m: Dictionary = ClosureMetricsScript.compute(model, null, null, 24.0)
	var expected := float(m.get("autonomy_person_days", 0.0)) * ClosureMetricsScript.SCORE_AUTONOMY_WEIGHT \
			+ float(m.get("mean_closure_pct", 0.0)) * ClosureMetricsScript.SCORE_CLOSURE_WEIGHT
	_check("score formula", absf(float(m.get("score", 0.0)) - expected) < 0.01,
			"score=%.2f expected=%.2f" % [float(m.get("score", 0.0)), expected])
	_check("occupants=2", int(m.get("occupants", 0)) == 2)


func _test_high_score_store() -> void:
	var lat := 33.123456
	var lon := -115.654321
	var path := HighScoreStoreScript.path_for(lat, lon)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	var a: float = HighScoreStoreScript.record_if_best(lat, lon, "test", 100.0)
	_check("first score recorded", a == 100.0, "a=%.1f" % a)
	var b: float = HighScoreStoreScript.record_if_best(lat, lon, "test", 50.0)
	_check("lower score ignored", b == 0.0, "b=%.1f" % b)
	var c: float = HighScoreStoreScript.record_if_best(lat, lon, "test", 150.0)
	_check("higher score recorded", c == 150.0, "c=%.1f" % c)
	_check("best is 150", HighScoreStoreScript.best_score(lat, lon, "test") == 150.0)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


func _test_energy_round_trip_efficiency() -> void:
	# Battery 10 kWh full, steady 0.2 kW load over 24 h (light enough that the
	# timeline SOC stays positive). Autonomy must use USABLE stock (timeline SOC
	# × 0.95 charge × 0.95 discharge), while "stock" stays undiscounted for UI.
	var model := GraphModelScript.new()
	model.add_item({
		"id": "bat", "type": "battery", "x": 0.0, "y": 0.0,
		"specs": {"kwh": 10.0, "soc": 1.0, "voltage": 48.0},
	})
	var et := EnergyTimelineScript.new()
	et.configure(10.0, 0.95, 0.95, 0.0)
	et.init_anchor(0.0, 10.0, 0.0, 0.0, 0.2)
	et.record_step(24.0, 0.0, 0.0, 0.2)
	var m: Dictionary = ClosureMetricsScript.compute(model, null, et, 24.0)
	var energy: Dictionary = (m.get("channels", {}) as Dictionary).get("energy", {}) as Dictionary
	var usable := float(energy.get("stock_usable", 0.0))
	var stock := float(energy.get("stock", 0.0))
	var soc_now := et.soc_at(24.0)
	_check("stock reports timeline SOC", absf(stock - soc_now) < 0.05,
			"stock=%.3f soc=%.3f" % [stock, soc_now])
	_check("stock_usable = stock × 0.9025",
			absf(usable - stock * ClosureMetricsScript.BATTERY_ROUND_TRIP_EFF) < 0.001,
			"usable=%.4f stock=%.4f" % [usable, stock])
	# demand ≈ 4.8 kWh over the 24 h window → daily demand 4.8 → autonomy = usable/4.8.
	var days := float(energy.get("autonomy_days", -1.0))
	var demand := float(energy.get("demand", 0.0))
	var expected_days := usable / maxf(demand * (24.0 / 24.0), 0.001)
	_check("autonomy uses usable stock", absf(days - expected_days) < 0.005,
			"days=%.4f expected=%.4f" % [days, expected_days])
	# Ideal-battery override restores nameplate autonomy.
	var m2: Dictionary = ClosureMetricsScript.compute(model, null, et, 24.0,
			ClosureMetricsScript.WINDOW_HOURS, 1.0)
	var energy2: Dictionary = (m2.get("channels", {}) as Dictionary).get("energy", {}) as Dictionary
	_check("efficiency override 1.0 → usable == stock",
			absf(float(energy2.get("stock_usable", 0.0)) - float(energy2.get("stock", -1.0))) < 0.001)


func _test_resource_timeline_integrate() -> void:
	var tl := preload("res://core/resource_timeline.gd").new()
	tl.configure(100.0)
	tl.init_anchor(0.0, 0.0)
	tl.record_step(1.0, 10.0, 10.0, 0.0)
	tl.record_step(2.0, 10.0, 10.0, 0.0)
	var infl: float = tl.integrate_channel(0.0, 2.0, "inflow")
	_check("resource integrate inflow ~20", infl > 18.0 and infl < 22.0, "infl=%.2f" % infl)
