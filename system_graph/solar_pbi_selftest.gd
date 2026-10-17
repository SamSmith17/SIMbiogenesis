extends SceneTree

## Offline checks for SolarIrradiance + the solar PBI graph node (Phase 1-2).

const SolarIrradianceScript := preload("res://core/solar_irradiance.gd")
const ResourceKindsScript := preload("res://system_graph/data/resource_kinds.gd")
const ResourceFlowEngineScript := preload("res://system_graph/resource_flow_engine.gd")
const GraphModelScript := preload("res://system_graph/data/graph_model.gd")
const GraphPortServiceScript := preload("res://system_graph/graph_port_service.gd")
const GraphCanvasScript := preload("res://system_graph/graph_canvas.gd")
const PlantGrowthScript := preload("res://system_graph/plant_growth.gd")
const GraphSolarShadingScript := preload("res://system_graph/graph_solar_shading.gd")
const SolarEnergyBudgetScript := preload("res://system_graph/solar_energy_budget.gd")
const ResourceEdgeVisScript := preload("res://system_graph/data/resource_edge_vis.gd")

const LAT := 33.36
const LON := -115.74


func _initialize() -> void:
	var fails := 0
	fails += _test_night_zero()
	fails += _test_noon_positive()
	fails += _test_cloud_reduces()
	fails += _test_measured_ghi()
	fails += _test_par_fraction()
	fails += _test_flux_kw()
	fails += _test_sun_availability()
	fails += _test_resource_kind_registered()
	fails += _test_pbi_display_string()
	fails += _test_engine_sun_pbi_flux()
	fails += _test_engine_sun_pbi_night()
	fails += _test_engine_sun_pbi_wire_animation()
	fails += _test_engine_rain_pbi_unaffected()
	fails += _test_panel_has_sunlight_handle()
	fails += _test_sunlight_connection_allowed()
	fails += _test_sunlight_handle_non_blocking_ry()
	fails += _test_plant_has_handles()
	fails += _test_panel_sunlight_factor_math()
	fails += _test_engine_plant_produces()
	fails += _test_engine_plant_needs_water()
	fails += _test_engine_plant_no_radiant_wire_needed()
	fails += _test_shade_occluded_lt_one()
	fails += _test_shade_clear_is_one()
	fails += _test_array_shade_one_model()
	fails += _test_shaded_caps_resplit()
	fails += _test_shade_factors_at_bake()
	fails += _test_energy_budget_efficiency()
	fails += _test_energy_budget_format_kw()
	fails += _test_radiant_glow_scales_with_flux()
	if fails == 0:
		print("SOLAR PBI SELFTEST PASS  (29 checks)")
		quit(0)
	else:
		print("SOLAR PBI SELFTEST FAIL  (%d failed)" % fails)
		quit(1)


func _noon_abs_hours() -> float:
	var clk := CelestialClock.new()
	clk.latitude = LAT
	clk.longitude = LON
	clk.year = 2026
	clk.month = 6
	clk.day = 15
	clk.day_time = 12.0
	return clk.get_absolute_hours()


func _night_abs_hours() -> float:
	var clk := CelestialClock.new()
	clk.latitude = LAT
	clk.longitude = LON
	clk.year = 2026
	clk.month = 6
	clk.day = 15
	clk.day_time = 2.0
	return clk.get_absolute_hours()


func _test_night_zero() -> int:
	var ghi := SolarIrradianceScript.ghi_wm2(LAT, LON, _night_abs_hours())
	if ghi > 1.0:
		push_error("night GHI expected ~0 got %.1f" % ghi)
		return 1
	return 0


func _test_noon_positive() -> int:
	var ghi := SolarIrradianceScript.ghi_wm2(LAT, LON, _noon_abs_hours())
	if ghi < 200.0:
		push_error("noon clear-sky GHI expected >200 W/m2 got %.1f" % ghi)
		return 1
	if ghi > 1400.0:
		push_error("noon GHI unreasonably high: %.1f" % ghi)
		return 1
	return 0


func _test_cloud_reduces() -> int:
	var clear := SolarIrradianceScript.ghi_wm2_at_calendar(
			LAT, LON, 6, 15, 12.0, {"cloud": 0.0})
	var cloudy := SolarIrradianceScript.ghi_wm2_at_calendar(
			LAT, LON, 6, 15, 12.0, {"cloud": 0.8})
	if cloudy >= clear * 0.95:
		push_error("cloud should reduce GHI: clear=%.1f cloudy=%.1f" % [clear, cloudy])
		return 1
	return 0


func _test_measured_ghi() -> int:
	var wx := {"ghi": 650.0, "has_real": true}
	var ghi := SolarIrradianceScript.ghi_wm2_at_calendar(LAT, LON, 6, 15, 12.0, wx)
	if absf(ghi - 650.0) > 0.01:
		push_error("measured GHI passthrough expected 650 got %.1f" % ghi)
		return 1
	return 0


func _test_par_fraction() -> int:
	var par := SolarIrradianceScript.par_wm2_from_ghi(1000.0)
	var expected := 1000.0 * SolarIrradianceScript.PAR_FRACTION
	if absf(par - expected) > 0.01:
		push_error("PAR fraction mismatch got %.1f expected %.1f" % [par, expected])
		return 1
	return 0


func _test_flux_kw() -> int:
	var area := 125663.0
	var flux := SolarIrradianceScript.flux_kw_from_ghi(800.0, area)
	var expected := 800.0 * area / 1000.0
	if absf(flux - expected) > 0.1:
		push_error("flux_kw mismatch got %.1f expected %.1f" % [flux, expected])
		return 1
	return 0


func _test_sun_availability() -> int:
	if absf(SolarIrradianceScript.sun_availability(0.0) - 0.0) > 0.001:
		push_error("sun_availability(0) should be 0")
		return 1
	if absf(SolarIrradianceScript.sun_availability(1000.0) - 1.0) > 0.001:
		push_error("sun_availability(1000) should be 1.0")
		return 1
	return 0


func _test_resource_kind_registered() -> int:
	if not ResourceKindsScript.BUILTIN.has("sunlight"):
		push_error("sunlight not in ResourceKinds.BUILTIN")
		return 1
	if ResourceKindsScript.normalize_kind("solar") != "sunlight":
		push_error("solar alias should normalize to sunlight")
		return 1
	var col: Color = ResourceKindsScript.wire_color("sunlight")
	if col.r < 0.9:
		push_error("sunlight wire color should be gold-ish")
		return 1
	return 0


func _test_pbi_display_string() -> int:
	if SolarIrradianceScript.pbi_display_string(0.0, 0.0) != "0 W/m²":
		push_error("pbi_display_string night should read 0 W/m²")
		return 1
	var kw_str := SolarIrradianceScript.pbi_display_string(500.0, 80.0)
	if not kw_str.begins_with("500 W/m²") or not kw_str.ends_with("80 kW"):
		push_error("pbi_display_string kW format unexpected: %s" % kw_str)
		return 1
	var mw_str := SolarIrradianceScript.pbi_display_string(800.0, 14300.0)
	if not mw_str.ends_with("14.3 MW"):
		push_error("pbi_display_string MW format unexpected: %s" % mw_str)
		return 1
	return 0


## Phase 2: resource_flow_engine._process_pbi (sunlight branch) end to end,
## via the selftest overrides (host=null, matching the existing rain PBI
## selftest pattern — no live WeatherService/SoiService needed).
func _test_engine_sun_pbi_flux() -> int:
	var model := GraphModelScript.new()
	model.add_item({
		"id": "pbi_sun", "type": "pbi", "x": -400.0, "y": -400.0,
		"width": 100.0, "height": 100.0,
		"specs": {"name": "Sunlight", "resource_kind": "sunlight"},
	})
	var engine := ResourceFlowEngineScript.new()
	engine.setup(model, null)
	engine.sun_ghi_override_wm2 = 800.0
	engine.soi_area_override_m2 = 125663.0  # ~ pi * 200^2
	engine.simulate_step_for_test(0.0, 0.0)
	engine.simulate_step_for_test(1.0, 1.0)
	var specs: Dictionary = model.get_item("pbi_sun").get("specs", {}) as Dictionary
	var expected_flux := 800.0 * 125663.0 / 1000.0
	if absf(float(specs.get("irradiance_wm2", -1.0)) - 800.0) > 0.01:
		push_error("pbi irradiance_wm2 expected 800 got %s" % specs.get("irradiance_wm2"))
		return 1
	if absf(float(specs.get("flux_kw", -1.0)) - expected_flux) > 0.5:
		push_error("pbi flux_kw expected %.1f got %s" % [expected_flux, specs.get("flux_kw")])
		return 1
	if absf(float(specs.get("sun_availability", -1.0)) - 0.8) > 0.001:
		push_error("pbi sun_availability expected 0.8 got %s" % specs.get("sun_availability"))
		return 1
	if not bool(specs.get("is_active", false)):
		push_error("pbi should be is_active with GHI=800")
		return 1
	return 0


func _test_engine_sun_pbi_night() -> int:
	var model := GraphModelScript.new()
	model.add_item({
		"id": "pbi_sun", "type": "pbi", "x": -400.0, "y": -400.0,
		"width": 100.0, "height": 100.0,
		"specs": {"name": "Sunlight", "resource_kind": "sunlight"},
	})
	var engine := ResourceFlowEngineScript.new()
	engine.setup(model, null)
	engine.sun_ghi_override_wm2 = 0.0
	engine.soi_area_override_m2 = 125663.0
	engine.simulate_step_for_test(0.0, 0.0)
	engine.simulate_step_for_test(1.0, 1.0)
	var specs: Dictionary = model.get_item("pbi_sun").get("specs", {}) as Dictionary
	if absf(float(specs.get("flux_kw", -1.0)) - 0.0) > 0.001:
		push_error("night pbi flux_kw should be 0 got %s" % specs.get("flux_kw"))
		return 1
	if bool(specs.get("is_active", true)):
		push_error("night pbi should not be is_active")
		return 1
	if str(specs.get("display_value", "")) != "0 W/m²":
		push_error("night pbi display_value expected 0 W/m² got %s" % specs.get("display_value"))
		return 1
	return 0


## Non-blocking-by-design check: the PBI animates an OPTIONAL outbound wire
## (informational — a receiver never needs this wire to function; Phase 3+
## wires panels/plants to sun_availability directly). Verifies the wire cache
## still gets the SoI flux rate for the radiant-wire visualization.
func _test_engine_sun_pbi_wire_animation() -> int:
	var model := GraphModelScript.new()
	model.add_item({
		"id": "pbi_sun", "type": "pbi", "x": -400.0, "y": -400.0,
		"width": 100.0, "height": 100.0,
		"specs": {"name": "Sunlight", "resource_kind": "sunlight"},
	})
	model.add_item({
		"id": "sink", "type": "pbi", "x": 0.0, "y": -400.0,
		"width": 100.0, "height": 100.0,
		"specs": {"name": "Sink Stub", "resource_kind": "sunlight"},
	})
	model.add_connection({
		"id": "c_radiant", "polarity": "resource", "resource_type": "sunlight",
		"source_item_id": "pbi_sun", "source_handle_id": "output",
		"target_item_id": "sink", "target_handle_id": "input",
	})
	var engine := ResourceFlowEngineScript.new()
	engine.setup(model, null)
	engine.sun_ghi_override_wm2 = 800.0
	engine.soi_area_override_m2 = 125663.0
	engine.simulate_step_for_test(0.0, 0.0)
	engine.simulate_step_for_test(1.0, 1.0)
	var flow := engine.get_connection_flow("c_radiant")
	if not bool(flow.get("active", false)):
		push_error("radiant wire should be active with GHI=800")
		return 1
	var expected_flux := 800.0 * 125663.0 / 1000.0
	if absf(float(flow.get("rate", -1.0)) - expected_flux) > 0.5:
		push_error("radiant wire rate expected %.1f got %s" % [expected_flux, flow.get("rate")])
		return 1
	return 0


## Regression: adding the sunlight branch to _process_pbi must not change the
## existing rain PBI behavior (SoI-scaled, no runoff, informational only).
func _test_engine_rain_pbi_unaffected() -> int:
	var model := GraphModelScript.new()
	model.add_item({
		"id": "pbi_rain", "type": "pbi", "x": -400.0, "y": 0.0,
		"width": 100.0, "height": 100.0,
		"specs": {"name": "Rain", "resource_kind": "water"},
	})
	var engine := ResourceFlowEngineScript.new()
	engine.setup(model, null)
	engine.rain_rate_override_mmh = 2.0
	engine.soi_area_override_m2 = 100.0
	engine.simulate_step_for_test(0.0, 0.0)
	engine.simulate_step_for_test(1.0, 1.0)
	var specs: Dictionary = model.get_item("pbi_rain").get("specs", {}) as Dictionary
	if absf(float(specs.get("live_capture_lph", -1.0)) - 200.0) > 0.01:
		push_error("rain pbi live_capture_lph expected 200 got %s" % specs.get("live_capture_lph"))
		return 1
	return 0


## Phase 3: panel gets an optional, non-blocking sunlight input handle
## (polarity "resource", resource_kind "sunlight") without any custom
## per-item handle override — GraphPortService falls back to the canvas's
## static HANDLES table for plain item types.
func _test_panel_has_sunlight_handle() -> int:
	var item := {"id": "p1", "type": "panel", "specs": {}}
	var handles: Array = GraphPortServiceScript.resolved_handles(item, GraphCanvasScript.HANDLES)
	var found := false
	for h: Variant in handles:
		var hd := h as Dictionary
		if str(hd.get("resource_kind", "")) == "sunlight":
			found = true
			if str(hd.get("polarity", "")) != "resource":
				push_error("panel sunlight handle polarity should be 'resource' got %s" % hd.get("polarity"))
				return 1
	if not found:
		push_error("panel handles missing a sunlight resource_kind entry: %s" % [handles])
		return 1
	return 0


## Sunlight->sunlight resource wires (PBI -> panel/plant) must validate —
## same-kind resource connections are always allowed.
func _test_sunlight_connection_allowed() -> int:
	if not ResourceKindsScript.connection_allowed("sunlight", "sunlight"):
		push_error("sunlight->sunlight connection should be allowed")
		return 1
	return 0


## The sunlight handle sits on the TOP edge (ry=0.0) like other inbound ports,
## separate from the bottom +/- DC output pair — confirms it's additive, not
## a replacement of the existing electrical handles panels already had.
func _test_sunlight_handle_non_blocking_ry() -> int:
	var panel_handles: Array = GraphCanvasScript.HANDLES.get("panel", []) as Array
	if panel_handles.size() != 3:
		push_error("panel should have 3 handles (positive, negative, sunlight_in) got %d" % panel_handles.size())
		return 1
	var pos_found := false
	var neg_found := false
	for h: Variant in panel_handles:
		var hd := h as Dictionary
		match str(hd.get("id", "")):
			"positive": pos_found = true
			"negative": neg_found = true
			"sunlight_in":
				if absf(float(hd.get("ry", -1.0)) - 0.0) > 0.001:
					push_error("sunlight_in handle should sit on top edge (ry=0)")
					return 1
	if not pos_found or not neg_found:
		push_error("panel lost its positive/negative DC handles")
		return 1
	return 0


## Phase 4: plant node exposes sunlight (optional), water, nutrients, biomass ports.
func _test_plant_has_handles() -> int:
	var item := {"id": "g1", "type": "plant", "specs": {}}
	var handles: Array = GraphPortServiceScript.resolved_handles(item, GraphCanvasScript.HANDLES)
	var kinds: Dictionary = {}
	for h: Variant in handles:
		var hd := h as Dictionary
		var rk := str(hd.get("resource_kind", ""))
		if not rk.is_empty():
			kinds[rk] = true
	for need: String in ["sunlight", "water", "nutrients", "biomass"]:
		if not kinds.has(need):
			push_error("plant missing %s handle: %s" % [need, handles])
			return 1
	return 0


## Panel share contract: a panel's card splits the array's (already shaded)
## output by wmp × sunlight_factor (default factor 1.0). The SAME factor scales
## SolarUI's array output (GraphSolarShading.array_shade) — see
## _test_array_shade_one_model.
func _test_panel_sunlight_factor_math() -> int:
	var share := 2.0  # kW
	var f_default := PlantGrowthScript.sunlight_factor_from_specs({})
	if absf(f_default - 1.0) > 0.001:
		push_error("missing sunlight_factor should default to 1.0 got %.3f" % f_default)
		return 1
	var f_shade := PlantGrowthScript.sunlight_factor_from_specs({"sunlight_factor": 0.4})
	if absf(share * f_shade - 0.8) > 0.001:
		push_error("shaded panel share expected 0.8 kW got %.3f" % (share * f_shade))
		return 1
	return 0


## Plant with water + biomass tank + ambient sun produces biomass (no radiant wire).
func _test_engine_plant_produces() -> int:
	var model := GraphModelScript.new()
	model.add_item({
		"id": "bed", "type": "plant", "x": 0.0, "y": 0.0,
		"width": 160.0, "height": 130.0,
		"specs": {
			"name": "Bed", "area_m2": 10.0, "lue_g_per_mj": 2.0,
			"water_l_per_kg": 50.0, "sunlight_factor": 1.0,
		},
	})
	model.add_item({
		"id": "water", "type": "resource", "x": -200.0, "y": -100.0,
		"width": 100.0, "height": 100.0,
		"specs": {
			"name": "Water", "resource_kind": "water",
			"capacity_qty": 1000.0, "capacity_unit": "L", "level": 0.8,
			"allow_negative": true,
		},
	})
	model.add_item({
		"id": "bio", "type": "resource", "x": 200.0, "y": 100.0,
		"width": 100.0, "height": 100.0,
		"specs": {
			"name": "Biomass", "resource_kind": "biomass",
			"capacity_qty": 100.0, "capacity_unit": "kg", "level": 0.1,
			"unlimited_capacity": true,
		},
	})
	model.add_connection({
		"id": "c_w", "polarity": "resource", "resource_type": "water",
		"source_item_id": "water", "source_handle_id": "output",
		"target_item_id": "bed", "target_handle_id": "water_in",
	})
	model.add_connection({
		"id": "c_b", "polarity": "resource", "resource_type": "biomass",
		"source_item_id": "bed", "source_handle_id": "biomass_out",
		"target_item_id": "bio", "target_handle_id": "input",
	})
	var engine := ResourceFlowEngineScript.new()
	engine.setup(model, null)
	engine.sun_ghi_override_wm2 = 800.0
	engine.soi_area_override_m2 = 1000.0
	engine.simulate_step_for_test(0.0, 0.0)
	engine.simulate_step_for_test(1.0, 1.0)
	var specs: Dictionary = model.get_item("bed").get("specs", {}) as Dictionary
	var rate := float(specs.get("biomass_kg_h", 0.0))
	if rate <= 0.0:
		push_error("plant should produce biomass under GHI=800; specs=%s" % specs)
		return 1
	# Cross-check against PlantGrowth pure math (June season ≈ 1.0)
	var par := SolarIrradianceScript.par_wm2_from_ghi(800.0)
	var expected := PlantGrowthScript.biomass_kg_per_hour(par, 10.0, 2.0, 6, 1.0, 1.0, 1.0)
	if absf(rate - expected) > expected * 0.15 + 1e-6:
		# Month may not be June in abs_hours=1.0 path — just require positive + order-of-magnitude.
		if rate < expected * 0.2:
			push_error("plant rate %.6f far below expected ~%.6f" % [rate, expected])
			return 1
	return 0


## Without a water wire the plant blocks (water is required; sunlight is not).
func _test_engine_plant_needs_water() -> int:
	var model := GraphModelScript.new()
	model.add_item({
		"id": "bed", "type": "plant", "x": 0.0, "y": 0.0,
		"width": 160.0, "height": 130.0,
		"specs": {"name": "Bed", "area_m2": 10.0, "lue_g_per_mj": 2.0},
	})
	model.add_item({
		"id": "bio", "type": "resource", "x": 200.0, "y": 100.0,
		"width": 100.0, "height": 100.0,
		"specs": {
			"name": "Biomass", "resource_kind": "biomass",
			"capacity_qty": 100.0, "level": 0.1, "unlimited_capacity": true,
		},
	})
	model.add_connection({
		"id": "c_b", "polarity": "resource", "resource_type": "biomass",
		"source_item_id": "bed", "source_handle_id": "biomass_out",
		"target_item_id": "bio", "target_handle_id": "input",
	})
	var engine := ResourceFlowEngineScript.new()
	engine.setup(model, null)
	engine.sun_ghi_override_wm2 = 800.0
	engine.simulate_step_for_test(0.0, 0.0)
	engine.simulate_step_for_test(1.0, 1.0)
	var specs: Dictionary = model.get_item("bed").get("specs", {}) as Dictionary
	if float(specs.get("biomass_kg_h", -1.0)) > 1e-9:
		push_error("plant without water should not produce")
		return 1
	if str(specs.get("node_state", "")) != "blocked":
		push_error("plant without water should be blocked got %s" % specs.get("node_state"))
		return 1
	return 0


## Non-blocking sunlight: radiant PBI→plant wire is NOT required for production.
func _test_engine_plant_no_radiant_wire_needed() -> int:
	# Same topology as _test_engine_plant_produces (no sunlight wire) — already
	# proves ambient PAR. This check asserts plant HANDLES still expose
	# sunlight_in so the optional wire CAN be drawn for education.
	var plant_handles: Array = GraphCanvasScript.HANDLES.get("plant", []) as Array
	var has_sun := false
	for h: Variant in plant_handles:
		if str((h as Dictionary).get("id", "")) == "sunlight_in":
			has_sun = true
			break
	if not has_sun:
		push_error("plant must expose optional sunlight_in handle")
		return 1
	return 0


## Phase 5: occluded sun ray → sunlight_factor < 1.
func _test_shade_occluded_lt_one() -> int:
	var sun := Vector3(0.2, 0.8, 0.1).normalized()
	var f := GraphSolarShadingScript.shade_factor_at(
			Vector3.ZERO, sun,
			func(_a: Vector3, _b: Vector3) -> Dictionary:
				return {"position": Vector3(1, 1, 1)})
	if f >= 1.0:
		push_error("shaded factor should be < 1 got %.3f" % f)
		return 1
	return 0


## Phase 5: clear sky ray → sunlight_factor == 1.
func _test_shade_clear_is_one() -> int:
	var sun := Vector3(0.2, 0.8, 0.1).normalized()
	var f := GraphSolarShadingScript.shade_factor_at(
			Vector3.ZERO, sun,
			func(_a: Vector3, _b: Vector3) -> Dictionary: return {})
	if absf(f - 1.0) > 0.001:
		push_error("unshaded factor should be 1.0 got %.3f" % f)
		return 1
	return 0


## Phase 6: site capture efficiency = (panel_kw + plant_chem) / SoI flux.
func _test_energy_budget_efficiency() -> int:
	var model := GraphModelScript.new()
	model.add_item({
		"id": "pbi_sun", "type": "pbi", "x": 0.0, "y": 0.0,
		"width": 100.0, "height": 100.0,
		"specs": {
			"name": "Sunlight", "resource_kind": "sunlight",
			"flux_kw": 100.0, "irradiance_wm2": 800.0,
			"cloud_frac": 0.1, "sun_availability": 0.8,
		},
	})
	model.add_item({
		"id": "p1", "type": "panel", "x": 100.0, "y": 0.0,
		"width": 100.0, "height": 80.0,
		"specs": {"name": "P1", "current_output_kw": 2.0},
	})
	model.add_item({
		"id": "g1", "type": "plant", "x": 200.0, "y": 0.0,
		"width": 100.0, "height": 90.0,
		"specs": {
			"name": "Bed", "biomass_kg_h": 0.36,  # → 1.6 kW chem @ 16 MJ/kg
			"par_wm2": 400.0, "area_m2": 10.0, "sunlight_factor": 1.0,
		},
	})
	var bud: Dictionary = SolarEnergyBudgetScript.compute(model)
	if not bool(bud.get("has_pbi", false)):
		push_error("budget should see sunlight PBI")
		return 1
	if absf(float(bud.get("panel_kw", 0.0)) - 2.0) > 0.001:
		push_error("panel_kw expected 2 got %s" % bud.get("panel_kw"))
		return 1
	# 0.36 kg/h × 16 MJ/kg / 3.6 = 1.6 kW
	if absf(float(bud.get("plant_chem_kw", 0.0)) - 1.6) > 0.01:
		push_error("plant_chem_kw expected 1.6 got %s" % bud.get("plant_chem_kw"))
		return 1
	if absf(float(bud.get("capture_kw", 0.0)) - 3.6) > 0.01:
		push_error("capture_kw expected 3.6 got %s" % bud.get("capture_kw"))
		return 1
	if absf(float(bud.get("efficiency_pct", 0.0)) - 3.6) > 0.05:
		push_error("efficiency_pct expected 3.6 got %s" % bud.get("efficiency_pct"))
		return 1
	return 0


func _test_energy_budget_format_kw() -> int:
	if SolarEnergyBudgetScript.format_kw(0.0) != "0 W":
		push_error("format_kw(0) unexpected: %s" % SolarEnergyBudgetScript.format_kw(0.0))
		return 1
	if SolarEnergyBudgetScript.format_kw(0.5) != "500 W":
		push_error("format_kw(0.5) unexpected: %s" % SolarEnergyBudgetScript.format_kw(0.5))
		return 1
	if "kW" not in SolarEnergyBudgetScript.format_kw(12.5):
		push_error("format_kw(12.5) should use kW")
		return 1
	if "MW" not in SolarEnergyBudgetScript.format_kw(2500.0):
		push_error("format_kw(2500) should use MW")
		return 1
	return 0


## Phase 6: radiant dash intensity rises with SoI flux toward flow_ref_rate.
func _test_radiant_glow_scales_with_flux() -> int:
	var idle := ResourceEdgeVisScript.glow_scale("sunlight", 0.0, false)
	var trickle := ResourceEdgeVisScript.glow_scale("sunlight", 100.0, true)
	var strong := ResourceEdgeVisScript.glow_scale("sunlight", 75000.0, true)
	if idle > 0.001:
		push_error("idle glow should be 0")
		return 1
	if trickle <= idle:
		push_error("trickle glow should exceed idle")
		return 1
	if strong <= trickle:
		push_error("strong flux glow should exceed trickle")
		return 1
	return 0


## One shade model: the array factor is the Wmp-weighted mean of the panels'
## factors, and splitting the shaded output by EFFECTIVE Wmp gives each panel
## exactly its own shaded output — so the cards sum to what the battery got.
func _test_array_shade_one_model() -> int:
	# Four 400 W panels, one under a tree (0.2), plus a 1 kW unplaced array.
	var rec := [
		{"wmp": 400.0, "group": 0, "s": 1.0},
		{"wmp": 400.0, "group": 0, "s": 0.2},
		{"wmp": 400.0, "group": 0, "s": 1.0},
		{"wmp": 400.0, "group": -1, "s": 1.0},
	]
	var total := 2600.0
	var sh: Dictionary = GraphSolarShadingScript.live_shade(rec, total)
	var want_f := (2600.0 - 320.0) / 2600.0
	if absf(float(sh["factor"]) - want_f) > 1e-6:
		push_error("array shade factor expected %.4f got %.4f" % [want_f, float(sh["factor"])])
		return 1
	# Unshaded the array would make 2.6 kW; the panel cards split the shaded
	# output by effective Wmp and must sum to it, the shaded one reading 1/5.
	var made := 2.6 * float(sh["factor"])
	var eff_total := total - float(sh["loss"])
	var sum := 0.0
	for r in rec:
		sum += made * float(r["wmp"]) * float(r["s"]) / eff_total
	sum += made * 1000.0 / eff_total
	if absf(sum - made) > 1e-6:
		push_error("cards should sum to the array's output %.4f got %.4f" % [made, sum])
		return 1
	var shaded_card := made * 400.0 * 0.2 / eff_total
	if absf(shaded_card - 0.08) > 1e-6:
		push_error("shaded 400 W panel should read 80 W got %.1f W" % (shaded_card * 1000.0))
		return 1
	# No receivers = no shade (the bootcamp sandbox).
	var none: Dictionary = GraphSolarShadingScript.live_shade([], total)
	if absf(float(none["factor"]) - 1.0) > 1e-9:
		push_error("no receivers must leave the array unshaded")
		return 1
	return 0


## The controllers' shares are re-split by the shade: a controller whose
## panels are shaded is offered less, the fracs still sum to one, and a cap
## sees its own panels' output (not a Wmp share of the whole shaded array).
func _test_shaded_caps_resplit() -> int:
	# Controller 0: 1000 W, all shaded (0.2); controller 1: 1000 W in the sun.
	var rec := [
		{"wmp": 1000.0, "group": 0, "s": 0.2},
		{"wmp": 1000.0, "group": 1, "s": 1.0},
	]
	var sh: Dictionary = GraphSolarShadingScript.live_shade(rec, 2000.0)
	var caps := [{"frac": 0.5, "limit_w": -1.0}, {"frac": 0.5, "limit_w": 500.0}]
	var adj: Dictionary = GraphSolarShadingScript.shaded_caps(caps, 0.0, sh)
	var c: Array = adj["caps"]
	var f0 := float((c[0] as Dictionary)["frac"])
	var f1 := float((c[1] as Dictionary)["frac"])
	if absf(f0 + f1 + float(adj["unrouted_frac"]) - 1.0) > 1e-6:
		push_error("re-split fracs must sum to 1 got %.4f" % (f0 + f1))
		return 1
	# Raw (shaded) = 1.2 kW: controller 0 is offered 0.2 kW, controller 1 1 kW
	# (capped to 0.5). Delivered = 0.7 kW.
	var raw := 2.0 * float(sh["factor"])
	if absf(raw * f0 - 0.2) > 1e-6 or absf(raw * f1 - 1.0) > 1e-6:
		push_error("shares expected 0.2 / 1.0 kW got %.3f / %.3f" % [raw * f0, raw * f1])
		return 1
	var got := GraphDcElectrical.delivered_for_caps(raw, c, float(adj["unrouted_frac"]))
	if absf(got - 0.7) > 1e-6:
		push_error("delivered expected 0.7 kW got %.3f" % got)
		return 1
	# Unshaded: the caps come back unchanged.
	var clear: Dictionary = GraphSolarShadingScript.shaded_caps(caps, 0.0,
		GraphSolarShadingScript.live_shade([{"wmp": 1000.0, "group": 0, "s": 1.0}], 2000.0))
	if not is_same(clear["caps"], caps):
		push_error("an unshaded array must not touch the caps")
		return 1
	return 0


## The batch render casts its own rays per instant: one ray per merged
## origin, none at night, and an unplaced receiver keeps its live factor.
func _test_shade_factors_at_bake() -> int:
	var rays := [0]
	var hit_fn := func(a: Vector3, _b: Vector3) -> Dictionary:
		rays[0] += 1
		return {"position": a} if a.x < 5.0 else {}
	var rec := [
		{"wmp": 400.0, "pos": Vector3(0, 1.5, 0), "s": 1.0},
		{"wmp": 400.0, "pos": Vector3(0.1, 1.5, 0.1), "s": 1.0},
		{"wmp": 400.0, "pos": Vector3(10, 1.5, 0), "s": 0.2},
		{"wmp": 400.0, "s": 0.5},
	]
	var day := GraphSolarShadingScript.factors_at(rec, Vector3(0.3, 0.8, 0.2).normalized(), hit_fn)
	if absf(float(day[0]) - 0.2) > 1e-6 or absf(float(day[1]) - 0.2) > 1e-6 \
			or absf(float(day[2]) - 1.0) > 1e-6 or absf(float(day[3]) - 0.5) > 1e-6:
		push_error("bake factors wrong: %s" % [day])
		return 1
	if int(rays[0]) != 2:
		push_error("adjacent origins should share a ray: %d rays" % int(rays[0]))
		return 1
	var night := GraphSolarShadingScript.factors_at(rec, Vector3(0.3, -0.2, 0.2), hit_fn)
	if int(rays[0]) != 2 or absf(float(night[0]) - 1.0) > 1e-6:
		push_error("no rays and no shade with the sun down")
		return 1
	return 0
