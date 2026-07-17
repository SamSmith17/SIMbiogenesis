extends SceneTree

## Offline checks for AtmospherePbi + Wind PBI graph node.

const AtmospherePbiScript := preload("res://system_graph/atmosphere_pbi.gd")
const ResourceKindsScript := preload("res://system_graph/data/resource_kinds.gd")
const ResourceFlowEngineScript := preload("res://system_graph/resource_flow_engine.gd")
const GraphModelScript := preload("res://system_graph/data/graph_model.gd")
const GraphCanvasScript := preload("res://system_graph/graph_canvas.gd")


func _initialize() -> void:
	var fails := 0
	fails += _test_kind_registered()
	fails += _test_kinetic_zero_at_calm()
	fails += _test_kinetic_scales_v3()
	fails += _test_display_string()
	fails += _test_weather_class()
	fails += _test_engine_wind_pbi()
	fails += _test_engine_wind_wire()
	fails += _test_turbine_has_wind_in()
	fails += _test_wind_connection_allowed()
	if fails == 0:
		print("WIND PBI SELFTEST PASS  (9 checks)")
		quit(0)
	else:
		print("WIND PBI SELFTEST FAIL  (%d failed)" % fails)
		quit(1)


func _test_kind_registered() -> int:
	if not ResourceKindsScript.BUILTIN.has("wind"):
		push_error("wind not in ResourceKinds.BUILTIN")
		return 1
	if ResourceKindsScript.normalize_kind("atmosphere") != "wind":
		push_error("atmosphere should normalize to wind")
		return 1
	if ResourceKindsScript.normalize_kind("mechanical") != "wind":
		push_error("mechanical should normalize to wind")
		return 1
	return 0


func _test_kinetic_zero_at_calm() -> int:
	if AtmospherePbiScript.kinetic_flux_kw(0.0, 125663.0) > 0.0:
		push_error("calm wind should yield 0 kinetic")
		return 1
	return 0


func _test_kinetic_scales_v3() -> int:
	var area := 125663.0
	var k1 := AtmospherePbiScript.kinetic_flux_kw(5.0, area)
	var k2 := AtmospherePbiScript.kinetic_flux_kw(10.0, area)
	# v³: doubling wind → 8× power
	if k1 <= 0.0 or absf(k2 / k1 - 8.0) > 0.05:
		push_error("kinetic should scale with v^3 got %.3f / %.3f" % [k2, k1])
		return 1
	return 0


func _test_display_string() -> int:
	var s := AtmospherePbiScript.pbi_display_string(8.2, 22.4, 48.0)
	if "m/s" not in s or "°C" not in s or "%" not in s:
		push_error("display string unexpected: %s" % s)
		return 1
	return 0


func _test_weather_class() -> int:
	if AtmospherePbiScript.weather_visual_class(0.0, 0.0) != 0:
		push_error("clear should be class 0")
		return 1
	if AtmospherePbiScript.weather_visual_class(0.9, 0.0) != 3:
		push_error("overcast should be class 3")
		return 1
	if AtmospherePbiScript.weather_visual_class(0.2, 1.0) != 4:
		push_error("rain should be class 4")
		return 1
	return 0


func _test_engine_wind_pbi() -> int:
	var model := GraphModelScript.new()
	model.add_item({
		"id": "pbi_wind", "type": "pbi", "x": 0.0, "y": 0.0,
		"width": 100.0, "height": 100.0,
		"specs": {"name": "Wind", "resource_kind": "wind"},
	})
	var engine := ResourceFlowEngineScript.new()
	engine.setup(model, null)
	engine.wind_speed_override_ms = 10.0
	engine.wind_temp_override_c = 25.0
	engine.wind_humidity_override_pct = 40.0
	engine.wind_cloud_override = 0.3
	engine.soi_area_override_m2 = 125663.0
	engine.simulate_step_for_test(0.0, 0.0)
	engine.simulate_step_for_test(1.0, 1.0)
	var specs: Dictionary = model.get_item("pbi_wind").get("specs", {}) as Dictionary
	if absf(float(specs.get("wind_ms", -1.0)) - 10.0) > 0.01:
		push_error("wind_ms expected 10 got %s" % specs.get("wind_ms"))
		return 1
	if absf(float(specs.get("temp_c", -1.0)) - 25.0) > 0.01:
		push_error("temp_c expected 25 got %s" % specs.get("temp_c"))
		return 1
	var expected := AtmospherePbiScript.kinetic_flux_kw(10.0, 125663.0)
	if absf(float(specs.get("kinetic_kw", -1.0)) - expected) > 0.5:
		push_error("kinetic_kw expected %.1f got %s" % [expected, specs.get("kinetic_kw")])
		return 1
	if not bool(specs.get("is_active", false)):
		push_error("wind pbi should be active at 10 m/s")
		return 1
	return 0


func _test_engine_wind_wire() -> int:
	var model := GraphModelScript.new()
	model.add_item({
		"id": "pbi_wind", "type": "pbi", "x": 0.0, "y": 0.0,
		"width": 100.0, "height": 100.0,
		"specs": {"name": "Wind", "resource_kind": "wind"},
	})
	model.add_item({
		"id": "turb", "type": "wind", "x": 200.0, "y": 0.0,
		"width": 160.0, "height": 138.0,
		"specs": {"name": "Turbine", "rated_w": 1000.0},
	})
	model.add_connection({
		"id": "c_wind", "polarity": "resource", "resource_type": "wind",
		"source_item_id": "pbi_wind", "source_handle_id": "output",
		"target_item_id": "turb", "target_handle_id": "wind_in",
	})
	var engine := ResourceFlowEngineScript.new()
	engine.setup(model, null)
	engine.wind_speed_override_ms = 8.0
	engine.wind_temp_override_c = 20.0
	engine.wind_humidity_override_pct = 50.0
	engine.soi_area_override_m2 = 125663.0
	engine.simulate_step_for_test(0.0, 0.0)
	engine.simulate_step_for_test(1.0, 1.0)
	var flow := engine.get_connection_flow("c_wind")
	if not bool(flow.get("active", false)):
		push_error("wind wire should be active at 8 m/s")
		return 1
	var expected := AtmospherePbiScript.kinetic_flux_kw(8.0, 125663.0)
	if absf(float(flow.get("rate", -1.0)) - expected) > 0.5:
		push_error("wind wire rate expected %.1f got %s" % [expected, flow.get("rate")])
		return 1
	return 0


func _test_turbine_has_wind_in() -> int:
	var handles: Array = GraphCanvasScript.HANDLES.get("wind", []) as Array
	for hd: Dictionary in handles:
		if str(hd.get("id", "")) == "wind_in":
			if str(hd.get("resource_kind", "")) != "wind":
				push_error("wind_in should be resource_kind wind")
				return 1
			return 0
	push_error("wind turbine missing wind_in handle")
	return 1


func _test_wind_connection_allowed() -> int:
	if not ResourceKindsScript.connection_allowed("wind", "wind"):
		push_error("wind→wind connection should be allowed")
		return 1
	return 0
