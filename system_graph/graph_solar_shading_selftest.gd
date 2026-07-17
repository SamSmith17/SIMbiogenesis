extends SceneTree

## Offline checks for GraphSolarShading (Phase 5 per-node 3D shade).

const GraphSolarShadingScript := preload("res://system_graph/graph_solar_shading.gd")
const SolarIrradianceScript := preload("res://core/solar_irradiance.gd")
const ResourceFlowEngineScript := preload("res://system_graph/resource_flow_engine.gd")
const GraphModelScript := preload("res://system_graph/data/graph_model.gd")


func _initialize() -> void:
	var fails := 0
	fails += _test_night_clear()
	fails += _test_unshaded_clear()
	fails += _test_shaded_residual()
	fails += _test_sample_origin()
	fails += _test_receiver_types()
	fails += _test_cloud_reduces_clear_sky_ghi()
	fails += _test_engine_cloud_frac()
	if fails == 0:
		print("GRAPH SOLAR SHADING SELFTEST PASS  (7 checks)")
		quit(0)
	else:
		print("GRAPH SOLAR SHADING SELFTEST FAIL  (%d failed)" % fails)
		quit(1)


func _test_night_clear() -> int:
	# Below horizon → CLEAR (night is gated by GHI, not shade).
	var f := GraphSolarShadingScript.factor_from_hit({"position": Vector3.ZERO}, Vector3(0.5, 0.0, 0.5))
	if absf(f - GraphSolarShadingScript.CLEAR) > 0.001:
		push_error("night shade should be CLEAR got %.3f" % f)
		return 1
	return 0


func _test_unshaded_clear() -> int:
	var sun := Vector3(0.3, 0.9, 0.2).normalized()
	var f := GraphSolarShadingScript.shade_factor_at(
			Vector3(0, 1.5, 0), sun,
			func(_from: Vector3, _to: Vector3) -> Dictionary: return {})
	if absf(f - GraphSolarShadingScript.CLEAR) > 0.001:
		push_error("empty hit should be CLEAR got %.3f" % f)
		return 1
	return 0


func _test_shaded_residual() -> int:
	var sun := Vector3(0.3, 0.9, 0.2).normalized()
	var f := GraphSolarShadingScript.shade_factor_at(
			Vector3(0, 1.5, 0), sun,
			func(_from: Vector3, _to: Vector3) -> Dictionary:
				return {"position": Vector3(10, 20, 10), "collider": null})
	if f >= 1.0:
		push_error("occluded ray should yield factor < 1 got %.3f" % f)
		return 1
	if absf(f - GraphSolarShadingScript.SHADED_RESIDUAL) > 0.001:
		push_error("occluded factor expected residual %.2f got %.3f" % [
				GraphSolarShadingScript.SHADED_RESIDUAL, f])
		return 1
	return 0


func _test_sample_origin() -> int:
	var item := {
		"site_x_m": 10.0, "site_z_m": -5.0, "elevation_m": 42.0,
		"type": "panel", "specs": {},
	}
	var center := Vector3(100.0, 0.0, 200.0)
	var origin := GraphSolarShadingScript.sample_origin(item, null, center)
	var expect := Vector3(
			110.0, 42.0 + GraphSolarShadingScript.SAMPLE_HEIGHT_M, 195.0)
	if origin.distance_to(expect) > 0.01:
		push_error("sample_origin expected %s got %s" % [expect, origin])
		return 1
	return 0


func _test_receiver_types() -> int:
	if not GraphSolarShadingScript.is_receiver_type("panel"):
		push_error("panel should be a shade receiver")
		return 1
	if not GraphSolarShadingScript.is_receiver_type("plant"):
		push_error("plant should be a shade receiver")
		return 1
	if GraphSolarShadingScript.is_receiver_type("battery"):
		push_error("battery should not be a shade receiver")
		return 1
	return 0


## Clouds fold into shared PBI availability via GHI (clear-sky path).
func _test_cloud_reduces_clear_sky_ghi() -> int:
	var clear := SolarIrradianceScript.ghi_wm2_at_calendar(
			33.0, -115.0, 6, 15, 12.0, {"cloud": 0.0})
	var cloudy := SolarIrradianceScript.ghi_wm2_at_calendar(
			33.0, -115.0, 6, 15, 12.0, {"cloud": 0.9})
	if cloudy >= clear * 0.95:
		push_error("cloud should reduce clear-sky GHI: clear=%.1f cloudy=%.1f" % [clear, cloudy])
		return 1
	var avail_clear := SolarIrradianceScript.sun_availability(clear)
	var avail_cloudy := SolarIrradianceScript.sun_availability(cloudy)
	if avail_cloudy >= avail_clear:
		push_error("cloud should reduce sun_availability")
		return 1
	return 0


func _test_engine_cloud_frac() -> int:
	var model := GraphModelScript.new()
	model.add_item({
		"id": "pbi_sun", "type": "pbi", "x": 0.0, "y": 0.0,
		"width": 100.0, "height": 100.0,
		"specs": {"name": "Sunlight", "resource_kind": "sunlight"},
	})
	var engine := ResourceFlowEngineScript.new()
	engine.setup(model, null)
	engine.sun_ghi_override_wm2 = 600.0
	engine.sun_cloud_override = 0.7
	engine.soi_area_override_m2 = 100.0
	engine.simulate_step_for_test(0.0, 0.0)
	engine.simulate_step_for_test(1.0, 1.0)
	var specs: Dictionary = model.get_item("pbi_sun").get("specs", {}) as Dictionary
	if absf(float(specs.get("cloud_frac", -1.0)) - 0.7) > 0.001:
		push_error("cloud_frac expected 0.7 got %s" % specs.get("cloud_frac"))
		return 1
	if absf(float(specs.get("sun_availability", -1.0)) - 0.6) > 0.001:
		push_error("sun_availability expected 0.6 got %s" % specs.get("sun_availability"))
		return 1
	return 0
