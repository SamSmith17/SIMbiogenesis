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
	if fails == 0:
		print("GRAPH ELECTRICAL SELFTEST PASS  (6 checks)")
	else:
		print("GRAPH ELECTRICAL SELFTEST FAIL  (%d failed)" % fails)
	quit()


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
