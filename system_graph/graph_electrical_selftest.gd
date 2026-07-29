extends SceneTree

## Offline self-test for PV electrical math, graph layout, and wiring helpers.

const GraphModelScript := preload("res://system_graph/data/graph_model.gd")


func _initialize() -> void:
	var fails := 0
	fails += _test_voc_series()
	fails += _test_voc_parallel_branches()
	fails += _test_overvoltage_fault()
	fails += _test_layout_resolver()
	fails += _test_layout_bounds_filter()
	fails += _test_controller_reset()
	fails += _test_array_topology()
	fails += _test_array_wire_and_voc()
	fails += _test_controller_ranking()
	fails += _test_voc_across_supernode()
	fails += _test_short_circuit_direct()
	fails += _test_short_circuit_series_loop()
	fails += _test_parallel_bank_no_short()
	fails += _test_bus_voltage_topology()
	fails += _test_battery_overvoltage()
	fails += _test_controller_clip_values()
	if fails == 0:
		print("GRAPH ELECTRICAL SELFTEST PASS  (16 checks)")
	else:
		print("GRAPH ELECTRICAL SELFTEST FAIL  (%d failed)" % fails)
	quit()


# ---------------------------------------------------------------------------
# DC-side (GraphDcElectrical): banks, shorts, overcharge, current clipping
# ---------------------------------------------------------------------------

## Tutorial level 1: one wire straight from + to − of a single battery.
func _test_short_circuit_direct() -> int:
	var model: GraphModel = GraphModelScript.new()
	_add_battery(model, "b1", 12.0, 1.2)
	_dc_wire(model, "b1", "positive", "b1", "negative")
	var analysis := GraphDcElectrical.analyze(model, GraphNesting.flat_connections(model))
	var shorts: Array = analysis.get("shorts", []) as Array
	if shorts.size() != 1:
		push_error("expected 1 short for direct +→− wire, got %d" % shorts.size())
		return 1
	var s: Dictionary = shorts[0]
	if str(s.get("battery_id", "")) != "b1":
		push_error("short should name b1, got %s" % str(s))
		return 1
	if (s.get("conn_ids", []) as Array).is_empty():
		push_error("short should carry the offending wire id")
		return 1
	if absf(float(s.get("loop_emf_v", 0.0)) - 12.0) > 0.5:
		push_error("loop EMF expected ~12 got %s" % str(s.get("loop_emf_v")))
		return 1
	return 0


## A clean series pair is fine; closing the loop (B+ back to A−) is a dead
## short with the full 24 V around the loop (KVL).
func _test_short_circuit_series_loop() -> int:
	var model: GraphModel = GraphModelScript.new()
	_add_battery(model, "a", 12.0, 1.2)
	_add_battery(model, "b", 12.0, 1.2)
	_dc_wire(model, "a", "positive", "b", "negative")  # series link — legitimate
	var clean := GraphDcElectrical.analyze(model, GraphNesting.flat_connections(model))
	if not (clean.get("shorts", []) as Array).is_empty():
		push_error("open series chain must not read as a short")
		return 1
	var banks: Array = clean.get("banks", []) as Array
	if banks.size() != 1 or absf(float((banks[0] as Dictionary).get("bus_voltage", 0.0)) - 24.0) > 0.5:
		push_error("series pair should be one 24 V bank, got %s" % str(banks))
		return 1
	_dc_wire(model, "b", "positive", "a", "negative")  # closes the loop
	var looped := GraphDcElectrical.analyze(model, GraphNesting.flat_connections(model))
	var shorts: Array = looped.get("shorts", []) as Array
	if shorts.size() != 1:
		push_error("closed series loop should short, got %d" % shorts.size())
		return 1
	if absf(float((shorts[0] as Dictionary).get("loop_emf_v", 0.0)) - 24.0) > 1.0:
		push_error("series-loop EMF expected ~24 got %s" % str(shorts[0]))
		return 1
	return 0


## Tutorial level 5 trap: paralleling equal batteries is legitimate — same bus
## voltage, doubled capacity, NOT a short (zero net EMF around the loop).
func _test_parallel_bank_no_short() -> int:
	var model: GraphModel = GraphModelScript.new()
	_add_battery(model, "a", 12.0, 1.2)
	_add_battery(model, "b", 12.0, 1.2)
	_dc_wire(model, "a", "positive", "b", "positive")
	_dc_wire(model, "a", "negative", "b", "negative")
	var analysis := GraphDcElectrical.analyze(model, GraphNesting.flat_connections(model))
	if not (analysis.get("shorts", []) as Array).is_empty():
		push_error("equal parallel bank must not read as a short")
		return 1
	var banks: Array = analysis.get("banks", []) as Array
	if banks.size() != 1:
		push_error("expected one bank, got %d" % banks.size())
		return 1
	var bank: Dictionary = banks[0]
	if absf(float(bank.get("bus_voltage", 0.0)) - 12.0) > 0.5:
		push_error("parallel bank bus expected 12 got %s" % str(bank.get("bus_voltage")))
		return 1
	if absf(float(bank.get("capacity_kwh", 0.0)) - 2.4) > 0.01:
		push_error("parallel bank capacity expected 2.4 got %s" % str(bank.get("capacity_kwh")))
		return 1
	return 0


## 4S = 48 V; 2S2P = 24 V with series/parallel counts; a 12 V chain paralleled
## onto a 24 V chain flags mismatch (circulating current) without a fault.
func _test_bus_voltage_topology() -> int:
	var model: GraphModel = GraphModelScript.new()
	for i in 4:
		_add_battery(model, "s%d" % i, 12.0, 1.2)
	for i in 3:
		_dc_wire(model, "s%d" % i, "positive", "s%d" % (i + 1), "negative")
	var a := GraphDcElectrical.analyze(model, GraphNesting.flat_connections(model))
	var bank: Dictionary = (a.get("banks", []) as Array)[0]
	if absf(float(bank.get("bus_voltage", 0.0)) - 48.0) > 0.5 \
			or int(bank.get("series_count", 0)) != 4:
		push_error("4S bank expected 48 V ×4S, got %s" % str(bank))
		return 1
	# 2S2P: two series pairs, paralleled at both ends.
	var m2: GraphModel = GraphModelScript.new()
	for id in ["a1", "a2", "b1", "b2"]:
		_add_battery(m2, id, 12.0, 1.2)
	_dc_wire(m2, "a1", "positive", "a2", "negative")
	_dc_wire(m2, "b1", "positive", "b2", "negative")
	_dc_wire(m2, "a2", "positive", "b2", "positive")
	_dc_wire(m2, "a1", "negative", "b1", "negative")
	var a2an := GraphDcElectrical.analyze(m2, GraphNesting.flat_connections(m2))
	if not (a2an.get("shorts", []) as Array).is_empty():
		push_error("2S2P must not short")
		return 1
	var bank2: Dictionary = (a2an.get("banks", []) as Array)[0]
	if absf(float(bank2.get("bus_voltage", 0.0)) - 24.0) > 0.5 \
			or int(bank2.get("series_count", 0)) != 2 \
			or int(bank2.get("parallel_count", 0)) != 2:
		push_error("2S2P bank expected 24 V 2S2P, got %s" % str(bank2))
		return 1
	# Mismatched parallel: 24 V chain ∥ single 12 V battery → warn, not short.
	var m3: GraphModel = GraphModelScript.new()
	for id in ["c1", "c2", "d1"]:
		_add_battery(m3, id, 12.0, 1.2)
	_dc_wire(m3, "c1", "positive", "c2", "negative")
	_dc_wire(m3, "c2", "positive", "d1", "positive")
	_dc_wire(m3, "c1", "negative", "d1", "negative")
	var a3 := GraphDcElectrical.analyze(m3, GraphNesting.flat_connections(m3))
	if not (a3.get("shorts", []) as Array).is_empty():
		push_error("mismatched parallel chains should warn, not short")
		return 1
	if not bool(((a3.get("banks", []) as Array)[0] as Dictionary).get("mismatch", false)):
		push_error("mismatched parallel chains should set the mismatch flag")
		return 1
	return 0


## Tutorial level 2: 40 Voc panel wired straight to a 12 V battery overcharges
## it; the same panel behind a controller does not.
func _test_battery_overvoltage() -> int:
	var model: GraphModel = GraphModelScript.new()
	_add_battery(model, "bat", 12.0, 1.2)
	_add_panel(model, "p1", 40.0)
	_dc_wire(model, "p1", "positive", "bat", "positive")
	_dc_wire(model, "p1", "negative", "bat", "negative")
	var flat := GraphNesting.flat_connections(model)
	var analysis := GraphDcElectrical.analyze(model, flat)
	var faults := GraphDcElectrical.find_battery_overvoltage(model, flat, analysis, 25.0)
	if faults.size() != 1:
		push_error("expected 1 battery-overvoltage fault, got %d" % faults.size())
		return 1
	var f: Dictionary = faults[0]
	if absf(float(f.get("safe_v", 0.0)) - 12.0 * GraphDcElectrical.CHARGE_CEILING_RATIO) > 0.1:
		push_error("safe_v expected 14.6 got %s" % str(f.get("safe_v")))
		return 1
	# Behind a controller: no fault.
	var m2: GraphModel = GraphModelScript.new()
	_add_battery(m2, "bat", 12.0, 1.2)
	_add_panel(m2, "p1", 40.0)
	_add_controller(m2, "ctrl", 150.0)
	_dc_wire(m2, "p1", "positive", "ctrl", "pvPositive")
	_dc_wire(m2, "p1", "negative", "ctrl", "pvNegative")
	_dc_wire(m2, "ctrl", "batteryPositive", "bat", "positive")
	_dc_wire(m2, "ctrl", "batteryNegative", "bat", "negative")
	var flat2 := GraphNesting.flat_connections(m2)
	var an2 := GraphDcElectrical.analyze(m2, flat2)
	if not GraphDcElectrical.find_battery_overvoltage(m2, flat2, an2, 25.0).is_empty():
		push_error("panel behind a controller must not overcharge the battery")
		return 1
	return 0


## Tutorial levels 3–6: the curriculum wattages emerge from bus_V × I_max.
## 300 W @ 12 V×10 A → 120 W; 1200 W @ 12 V×30 A → 360 W; 24 V → 720 W;
## 48 V×30 A (1440 W cap) → array-limited 1200 W, not clipped.
func _test_controller_clip_values() -> int:
	var cases := [
		{"array_w": 300.0, "bus": 12.0, "amps": 10.0, "want": 120.0, "clipped": true},
		{"array_w": 1200.0, "bus": 12.0, "amps": 30.0, "want": 360.0, "clipped": true},
		{"array_w": 1200.0, "bus": 24.0, "amps": 30.0, "want": 720.0, "clipped": true},
		{"array_w": 1200.0, "bus": 48.0, "amps": 30.0, "want": 1200.0, "clipped": false},
	]
	for c_v in cases:
		var c: Dictionary = c_v
		var ctrl := {"type": "controller", "specs": {"max_charge_amps": float(c["amps"])}}
		var bank := {"bus_voltage": float(c["bus"])}
		var th := GraphDcElectrical.controller_throttle(ctrl, bank, float(c["array_w"]))
		if absf(float(th.get("delivered_w", 0.0)) - float(c["want"])) > 0.5:
			push_error("throttle %s expected %.0f W got %s" % [str(c), float(c["want"]), str(th)])
			return 1
		if bool(th.get("clipped", true)) != bool(c["clipped"]):
			push_error("throttle clipped flag wrong for %s: %s" % [str(c), str(th)])
			return 1
	# End-to-end: bank_for_controller resolves the wired bank (2S → 24 V).
	var model: GraphModel = GraphModelScript.new()
	_add_battery(model, "a", 12.0, 1.2)
	_add_battery(model, "b", 12.0, 1.2)
	_dc_wire(model, "a", "positive", "b", "negative")
	_add_controller(model, "ctrl", 150.0)
	_dc_wire(model, "ctrl", "batteryPositive", "b", "positive")
	_dc_wire(model, "ctrl", "batteryNegative", "a", "negative")
	var flat := GraphNesting.flat_connections(model)
	var analysis := GraphDcElectrical.analyze(model, flat)
	var bank2 := GraphDcElectrical.bank_for_controller(model, "ctrl", flat, analysis)
	if bank2.is_empty() or absf(float(bank2.get("bus_voltage", 0.0)) - 24.0) > 0.5:
		push_error("bank_for_controller expected 24 V bank, got %s" % str(bank2))
		return 1
	# No current limit modeled (amps ≤ 0) → array passes untouched.
	var free := GraphDcElectrical.controller_throttle(
		{"type": "controller", "specs": {}}, bank2, 5000.0)
	if absf(float(free.get("delivered_w", 0.0)) - 5000.0) > 0.5:
		push_error("no-amp-limit controller must not clip, got %s" % str(free))
		return 1
	return 0


## Nesting-aware Voc: a PV string whose panels live inside a super-node wired to
## a controller in the parent scope must still fault (find_overvoltage_faults_flat
## flattens the portals and scans every scope).
func _test_voc_across_supernode() -> int:
	var model: GraphModel = GraphModelScript.new()
	for i in 4:
		_add_panel(model, "sp%d" % i, 48.0)
	_add_controller(model, "ctrl", 150.0)
	# Series-chain panels inside the child scope.
	for i in 3:
		model.add_connection({"scope_id": "scope_grp", "polarity": "positive",
			"source_item_id": "sp%d" % i, "source_handle_id": "positive",
			"target_item_id": "sp%d" % (i + 1), "target_handle_id": "negative"})
	# Group them; expose the string ends.
	model.add_item({"id": "grp", "type": "compound", "x": 0, "y": 0,
		"width": 180, "height": 120, "scope_id": "root", "child_scope_id": "scope_grp",
		"handles": [
			{"id": "pv+", "polarity": "positive", "direction": "out", "rx": 1.0, "ry": 0.4},
			{"id": "pv-", "polarity": "negative", "direction": "out", "rx": 1.0, "ry": 0.6}],
		"specs": {"compound_kind": "", "exposed_ports": [
			{"handle_id": "pv+", "child_item_id": "sp3", "child_handle_id": "positive",
				"direction": "out", "polarity": "positive"},
			{"handle_id": "pv-", "child_item_id": "sp0", "child_handle_id": "negative",
				"direction": "out", "polarity": "negative"}]}})
	model.ensure_scope("scope_grp", "root", "grp", "grp")
	for i in 4:
		model.update_item("sp%d" % i, {"scope_id": "scope_grp", "parent_compound_id": "grp"})
	model.add_connection({"scope_id": "root", "polarity": "positive",
		"source_item_id": "grp", "source_handle_id": "pv+",
		"target_item_id": "ctrl", "target_handle_id": "pvPositive"})
	model.add_connection({"scope_id": "root", "polarity": "negative",
		"source_item_id": "grp", "source_handle_id": "pv-",
		"target_item_id": "ctrl", "target_handle_id": "pvNegative"})
	var faults := PvElectrical.find_overvoltage_faults_flat(model, 25.0)
	if faults.size() != 1:
		push_error("expected 1 over-voltage fault across super-node, got %d" % faults.size())
		return 1
	return 0


func _test_voc_series() -> int:
	var model: GraphModel = GraphModelScript.new()
	var p1 := _add_panel(model, "p1", 48.0)
	var p2 := _add_panel(model, "p2", 48.0)
	var p3 := _add_panel(model, "p3", 48.0)
	var ctrl := _add_controller(model, "ctrl", 100.0)
	GraphPvWiring.wire_series(model, ["p1", "p2", "p3"], "ctrl")
	var voc := PvElectrical.max_string_voc_for_controller(model, "ctrl", "root", 25.0)
	if absf(voc - 144.0) > 0.5:
		push_error("series voc expected ~144 got %f" % voc)
		return 1
	return 0


func _test_voc_parallel_branches() -> int:
	var model: GraphModel = GraphModelScript.new()
	_add_panel(model, "a1", 40.0)
	_add_panel(model, "a2", 40.0)
	_add_panel(model, "b1", 50.0)
	var ctrl := _add_controller(model, "ctrl", 200.0)
	GraphPvWiring.add_pv_connection(model, "positive", "a1", "positive", "a2", "negative")
	GraphPvWiring.add_pv_connection(model, "positive", "a1", "negative", "ctrl", "pvNegative")
	GraphPvWiring.add_pv_connection(model, "positive", "a2", "positive", "ctrl", "pvPositive")
	GraphPvWiring.add_pv_connection(model, "positive", "b1", "positive", "ctrl", "pvPositive")
	GraphPvWiring.add_pv_connection(model, "negative", "b1", "negative", "ctrl", "pvNegative")
	var vocs: Array = PvElectrical.branch_vocs_for_controller(model, "ctrl", "root", 25.0)
	var max_v := 0.0
	for v in vocs:
		max_v = maxf(max_v, float(v))
	if absf(max_v - 80.0) > 0.5:
		push_error("parallel branch max voc expected ~80 got %f branches=%s" % [max_v, str(vocs)])
		return 1
	return 0


func _test_overvoltage_fault() -> int:
	var model: GraphModel = GraphModelScript.new()
	var panels: Array[String] = []
	for i in 4:
		panels.append("p%d" % i)
		_add_panel(model, "p%d" % i, 48.0)
	var ctrl := _add_controller(model, "ctrl", 150.0)
	GraphPvWiring.wire_series(model, panels, "ctrl")
	var faults := PvElectrical.find_overvoltage_faults(model, "root", 25.0)
	if faults.is_empty():
		push_error("expected overvoltage fault for 4x48V series on 150V controller")
		return 1
	return 0


func _test_layout_resolver() -> int:
	var items: Array = [
		{"id": "a", "x": 0.0, "y": 0.0, "width": 100.0, "height": 80.0},
		{"id": "b", "x": 10.0, "y": 10.0, "width": 100.0, "height": 80.0},
	]
	var patches: Dictionary = GraphLayout.resolve_overlaps(items, 16.0, 64)
	var ra := GraphLayout.item_rect({"id": "a", "x": (patches["a"] as Vector2).x,
		"y": (patches["a"] as Vector2).y, "width": 100.0, "height": 80.0})
	var rb := GraphLayout.item_rect({"id": "b", "x": (patches["b"] as Vector2).x,
		"y": (patches["b"] as Vector2).y, "width": 100.0, "height": 80.0})
	if GraphLayout.rects_overlap(ra, rb):
		push_error("layout resolver left overlapping rects")
		return 1
	return 0


func _test_layout_bounds_filter() -> int:
	var items: Array = [
		{"id": "virtual_solar_array", "x": -1650.0, "y": -1050.0, "width": 168.0, "height": 96.0,
			"layout_exclude": true},
		{"id": "virtual_controller", "x": 140.0, "y": -120.0, "width": 140.0, "height": 120.0},
		{"id": "virtual_battery", "x": 340.0, "y": -100.0, "width": 100.0, "height": 136.0},
	]
	var bounds := GraphLayout.content_bounds(items)
	if bounds.position.x < -500.0:
		push_error("layout bounds filter still includes off-canvas virtual_solar_array")
		return 1
	if GraphLayout.include_in_layout(items[0] as Dictionary):
		push_error("virtual_solar_array should be excluded from layout")
		return 1
	return 0


func _test_controller_reset() -> int:
	var model: GraphModel = GraphModelScript.new()
	var ctrl := _add_controller(model, "ctrl", 150.0)
	var sp: Dictionary = (model.get_item("ctrl").get("specs", {}) as Dictionary).duplicate(true)
	sp["destroyed"] = true
	sp["destroyed_reason"] = "test"
	model.update_item("ctrl", {"specs": sp})
	sp = model.get_item("ctrl").get("specs", {}) as Dictionary
	sp["destroyed"] = false
	sp.erase("destroyed_reason")
	model.update_item("ctrl", {"specs": sp})
	if bool((model.get_item("ctrl").get("specs", {}) as Dictionary).get("destroyed", true)):
		push_error("controller reset did not clear destroyed flag")
		return 1
	return 0


func _test_array_topology() -> int:
	# 12 panels @ 48 V on a 150 V controller → max series = 3 → 3S×4P.
	var topo := SolarArrayIntelligence.best_series_parallel(12, 48.0, 150.0)
	if int(topo.get("series", 0)) != 3:
		push_error("expected series 3 got %s" % str(topo))
		return 1
	if int(topo.get("parallel", 0)) != 4:
		push_error("expected parallel 4 got %s" % str(topo))
		return 1
	if absf(float(topo.get("equiv_voc", 0.0)) - 144.0) > 0.5:
		push_error("expected equiv_voc 144 got %s" % str(topo))
		return 1
	# Panel Voc alone exceeds controller → fitted 0.
	var bad := SolarArrayIntelligence.best_series_parallel(6, 200.0, 150.0)
	if int(bad.get("fitted", 1)) != 0:
		push_error("expected fitted 0 when panel Voc > max_voc")
		return 1
	return 0


func _test_array_wire_and_voc() -> int:
	var model: GraphModel = GraphModelScript.new()
	var array_id := "arr1"
	var topo := SolarArrayIntelligence.best_series_parallel(6, 48.0, 150.0)
	var equiv := SolarArrayIntelligence.build_array_equiv_specs(
			6, 400.0, 48.0, 41.0, 9.76, 11.0, topo)
	model.add_item({
		"id": array_id, "type": "compound", "x": 0.0, "y": 0.0,
		"width": 200.0, "height": 140.0, "scope_id": "root",
		"specs": {
			"compound_kind": "array",
			"array_equiv_voc": float(equiv.get("array_equiv_voc", 0.0)),
			"array_panel_units": 6,
			"osm_import": true, "osm_tag": "osm_solar_0_0",
		},
	})
	_add_controller(model, "ctrl", 150.0)
	SolarArrayIntelligence.wire_array_to_controller(model, array_id, "ctrl", "root")
	var voc := PvElectrical.max_string_voc_for_controller(model, "ctrl", "root", 25.0)
	var want := float(equiv.get("array_equiv_voc", 0.0))
	if absf(voc - want) > 0.5:
		push_error("array compound Voc expected ~%f got %f" % [want, voc])
		return 1
	if not PvElectrical.is_pv_source_item(model.get_item(array_id)):
		push_error("array compound should be a PV source")
		return 1
	return 0


func _test_controller_ranking() -> int:
	var model: GraphModel = GraphModelScript.new()
	_add_controller(model, "near", 150.0)
	model.update_item("near", {"x": 50.0, "y": 0.0})
	_add_controller(model, "far_big", 500.0)
	model.update_item("far_big", {"x": 2000.0, "y": 0.0})
	# 20 panels × 48 V needs ~3S (144 V) — both fit; nearer 150 V should rank high.
	var ranked := SolarArrayIntelligence.rank_controllers(
			model, Vector2(0.0, 0.0), 20, 48.0, 400.0, "root")
	if ranked.is_empty():
		push_error("expected ranked controllers")
		return 1
	var top: Dictionary = ranked[0]
	# Top should be an on-canvas fit (near) or a fitting preset — not a over-Voc.
	if not bool(top.get("fits", false)):
		push_error("top-ranked controller should fit Voc")
		return 1
	var rec := SolarArrayIntelligence.recommend_controller_preset(20, 48.0, 400.0)
	if rec.is_empty() or not (rec.get("specs", {}) is Dictionary):
		push_error("recommend_controller_preset returned empty")
		return 1
	var max_voc := float((rec.get("specs", {}) as Dictionary).get("max_voc", 0.0))
	if max_voc < 144.0:
		push_error("recommended preset max_voc too low: %f" % max_voc)
		return 1
	return 0


func _add_panel(model: GraphModel, id: String, voc: float) -> String:
	model.add_item({
		"id": id, "type": "panel", "x": 0.0, "y": 0.0, "width": 120.0, "height": 100.0,
		"scope_id": "root",
		"specs": {"voc": voc, "vmp": voc * 0.8, "wmp": 400.0, "imp": 10.0, "isc": 10.5},
	})
	return id


func _add_controller(model: GraphModel, id: String, max_voc: float) -> String:
	model.add_item({
		"id": id, "type": "controller", "x": 400.0, "y": 0.0, "width": 140.0, "height": 120.0,
		"scope_id": "root",
		"specs": {"max_voc": max_voc, "max_charge_amps": 30.0, "max_pv_watts": 2000.0},
	})
	return id


func _add_battery(model: GraphModel, id: String, voltage: float, kwh: float) -> String:
	model.add_item({
		"id": id, "type": "battery", "x": 0.0, "y": 300.0, "width": 110.0, "height": 80.0,
		"scope_id": "root",
		"specs": {"voltage": voltage, "ah": kwh * 1000.0 / maxf(voltage, 1.0), "kwh": kwh,
			"soc": 0.8},
	})
	return id


## Raw DC wire between two handles (polarity follows the source handle like the
## canvas does; GraphDcElectrical only requires it to be a DC polarity).
func _dc_wire(model: GraphModel, src: String, src_handle: String,
		tgt: String, tgt_handle: String) -> void:
	var pol := "negative" if src_handle.to_lower().contains("neg") else "positive"
	model.add_connection({"scope_id": "root", "polarity": pol,
		"source_item_id": src, "source_handle_id": src_handle,
		"target_item_id": tgt, "target_handle_id": tgt_handle})
