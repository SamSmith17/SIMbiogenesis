extends SceneTree

## Headless self-test for reversible resource timelines + habitat demand.
## Run with:
##   Godot.exe.exe --headless --path . --script power_system/sources/resource_flow_selftest.gd

const ResourceTimelineScript := preload("res://core/resource_timeline.gd")
const ResourceKindsScript := preload("res://system_graph/data/resource_kinds.gd")
const ResourceFlowEngineScript := preload("res://system_graph/resource_flow_engine.gd")
const GraphModelScript := preload("res://system_graph/data/graph_model.gd")
const PbiBiomassScript := preload("res://system_graph/pbi_biomass.gd")
const DcPowerWiringScript := preload("res://system_graph/dc_power_wiring.gd")
const GraphHubPortsScript := preload("res://system_graph/graph_hub_ports.gd")
const GraphPortServiceScript := preload("res://system_graph/graph_port_service.gd")

var _failures: int = 0
var _checks: int = 0


func _initialize() -> void:
	_test_step_level()
	_test_reversible_timeline()
	_test_processor_migration()
	_test_resource_migration()
	_test_habitat_24h_depletion()
	_test_habitat_waste_mass_balance()
	_test_habitat_starvation()
	_test_habitat_occupants_scale()
	_test_habitat_scrub_rewind()
	_test_biomass_catchment_manual_area()
	_test_biodigester_resource_kinds()
	_test_step_overflow_qty()
	_test_tank_overflow_tracking()
	_test_unlimited_capacity_sink()
	_test_rain_catchment_pbi_gate()
	_test_rain_catchment_full_tank_stops()
	_test_jit_tank_transfer()
	_test_processor_power_gating()
	_test_unconnected_output_flagged()
	_test_node_state_reasons()
	_test_habitat_node_state()
	_test_render_step_determinism()
	_test_biochar_electric_input_fix()
	_test_processor_ready_idle()
	_test_graph_ac_load_running_draws()
	_test_dc_electricity_port_topology()
	_test_dc_generator_output_telemetry()
	_test_dc_power_wiring_trace()
	_test_dc_direct_charge_migration()
	_test_graph_wind_hydro_dc_aggregation()
	_test_gravity_jit_gate()
	_test_site_layout_seed_and_clamp()
	if _failures == 0:
		print("RESOURCE SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("RESOURCE SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


func _test_step_level() -> void:
	var l0 := ResourceTimelineScript.step_level(0.5, 10.0, 100.0, 1.0)
	_check("step_level forward", absf(l0 - 0.6) < 0.001, "got %.3f" % l0)
	var back := ResourceTimelineScript.unstep_level(l0, 10.0, 100.0, 1.0)
	_check("unstep_level roundtrip", absf(back - 0.5) < 0.001, "got %.3f" % back)


func _test_reversible_timeline() -> void:
	var tl := ResourceTimelineScript.new()
	tl.configure(100.0)
	tl.init_anchor(0.0, 0.5)
	tl.record_step(1.0, 50.0, 50.0, 0.0)
	tl.record_step(2.0, 50.0, 50.0, 0.0)
	var fwd := tl.level_at(2.0)
	_check("timeline forward level > start", fwd > 0.5, "fwd=%.3f" % fwd)
	var rew := tl.seek(0.0)
	_check("timeline rewind to anchor", absf(float(rew.get("level", -1.0)) - 0.5) < 0.02,
		"rew=%.3f" % float(rew.get("level", -1.0)))


func _test_processor_migration() -> void:
	var specs := {"name": "Pump", "watts": 500.0, "output_rate": "50 L/h"}
	ResourceKindsScript.new().migrate_processor_specs(specs)
	_check("processor inputs array", specs.has("inputs"))
	_check("processor outputs array", (specs.get("outputs", []) as Array).size() > 0)


func _test_resource_migration() -> void:
	var specs := {"name": "Water Tank", "capacity": "50 gal", "level": 0.5}
	ResourceKindsScript.new().migrate_resource_specs(specs)
	_check("resource kind", specs.get("resource_kind", "") == "water")
	_check("resource capacity_qty", float(specs.get("capacity_qty", 0.0)) > 0.0)


## Build a minimal habitat graph: water + food in, grey/black/biomass out.
func _build_habitat_graph(occupants: int = 1, water_level: float = 1.0,
		food_level: float = 0.8) -> Dictionary:
	var model = GraphModelScript.new()
	model.add_item({
		"id": "hab", "type": "processor", "x": 0.0, "y": 0.0,
		"width": 150.0, "height": 150.0,
		"specs": {
			"name": "Habitat", "role": "habitat", "occupants": occupants,
			"watts": 0.0, "energy_source": "", "efficiency": 1.0,
			"inputs": [
				{"kind": "water", "rate": 2.083, "unit": "L/h"},
				{"kind": "food", "rate": 0.0625, "unit": "kg/h"},
			],
			"outputs": [
				{"kind": "greywater", "rate": 1.666, "unit": "L/h"},
				{"kind": "blackwater", "rate": 0.417, "unit": "L/h"},
				{"kind": "biomass", "rate": 0.0125, "unit": "kg/h"},
			],
		},
	})
	model.add_item({
		"id": "water", "type": "resource", "x": -200.0, "y": 0.0,
		"width": 90.0, "height": 100.0,
		"specs": {
			"name": "Water", "resource_kind": "water",
			"capacity_qty": 100.0, "capacity_unit": "L", "level": water_level,
		},
	})
	model.add_item({
		"id": "food", "type": "resource", "x": -200.0, "y": 120.0,
		"width": 90.0, "height": 100.0,
		"specs": {
			"name": "Food", "resource_kind": "food",
			"capacity_qty": 50.0, "capacity_unit": "kg", "level": food_level,
		},
	})
	model.add_item({
		"id": "grey", "type": "resource", "x": 200.0, "y": -40.0,
		"width": 90.0, "height": 100.0,
		"specs": {
			"name": "Grey", "resource_kind": "greywater",
			"capacity_qty": 200.0, "capacity_unit": "L", "level": 0.0,
		},
	})
	model.add_item({
		"id": "black", "type": "resource", "x": 200.0, "y": 60.0,
		"width": 90.0, "height": 100.0,
		"specs": {
			"name": "Black", "resource_kind": "blackwater",
			"capacity_qty": 100.0, "capacity_unit": "L", "level": 0.0,
		},
	})
	model.add_item({
		"id": "bio", "type": "resource", "x": 200.0, "y": 160.0,
		"width": 90.0, "height": 100.0,
		"specs": {
			"name": "Bio", "resource_kind": "biomass",
			"capacity_qty": 50.0, "capacity_unit": "kg", "level": 0.0,
		},
	})
	model.add_connection({
		"id": "c_w", "polarity": "resource", "resource_type": "water",
		"source_item_id": "water", "source_handle_id": "output",
		"target_item_id": "hab", "target_handle_id": "res_in_0",
	})
	model.add_connection({
		"id": "c_f", "polarity": "resource", "resource_type": "food",
		"source_item_id": "food", "source_handle_id": "output",
		"target_item_id": "hab", "target_handle_id": "res_in_1",
	})
	model.add_connection({
		"id": "c_g", "polarity": "resource", "resource_type": "greywater",
		"source_item_id": "hab", "source_handle_id": "res_out_0",
		"target_item_id": "grey", "target_handle_id": "input",
	})
	model.add_connection({
		"id": "c_b", "polarity": "resource", "resource_type": "blackwater",
		"source_item_id": "hab", "source_handle_id": "res_out_1",
		"target_item_id": "black", "target_handle_id": "input",
	})
	model.add_connection({
		"id": "c_bio", "polarity": "resource", "resource_type": "biomass",
		"source_item_id": "hab", "source_handle_id": "res_out_2",
		"target_item_id": "bio", "target_handle_id": "input",
	})
	var engine = ResourceFlowEngineScript.new()
	engine.setup(model, null)
	return {"model": model, "engine": engine}


func _tank_level(model, id: String) -> float:
	var item: Dictionary = model.get_item(id)
	return float((item.get("specs", {}) as Dictionary).get("level", -1.0))


func _test_habitat_24h_depletion() -> void:
	var g := _build_habitat_graph(1, 1.0, 0.8)
	var model = g["model"]
	var engine = g["engine"]
	# 1 person × 2.083 L/h × 24 h = 50 L from 100 L → level 0.50
	engine.simulate_step_for_test(0.0, 0.0)
	engine.simulate_step_for_test(24.0, 24.0)
	var wl := _tank_level(model, "water")
	_check("habitat 24h water ~0.50", absf(wl - 0.50) < 0.02, "water=%.3f" % wl)
	# Food: 0.0625 kg/h × 24 = 1.5 kg from 40 kg (0.8×50) → 38.5/50 = 0.77
	var fl := _tank_level(model, "food")
	_check("habitat 24h food ~0.77", absf(fl - 0.77) < 0.02, "food=%.3f" % fl)
	var hab: Dictionary = model.get_item("hab")
	var starved: Array = (hab.get("specs", {}) as Dictionary).get("starved_kinds", []) as Array
	_check("habitat not starved when supplied", starved.is_empty(), "starved=%s" % str(starved))


func _test_habitat_waste_mass_balance() -> void:
	var g := _build_habitat_graph(1, 1.0, 0.8)
	var model = g["model"]
	var engine = g["engine"]
	engine.simulate_step_for_test(0.0, 0.0)
	engine.simulate_step_for_test(24.0, 24.0)
	# Water consumed 50 L → grey 40 L (0.8) + black 10 L (0.2)
	var grey_l := _tank_level(model, "grey") * 200.0
	var black_l := _tank_level(model, "black") * 100.0
	_check("greywater ≤ water consumed", grey_l <= 50.0 + 0.5, "grey=%.2f" % grey_l)
	_check("blackwater ≤ water consumed", black_l <= 50.0 + 0.5, "black=%.2f" % black_l)
	_check("grey+black ≈ water consumed", absf(grey_l + black_l - 50.0) < 1.0,
		"sum=%.2f" % (grey_l + black_l))
	_check("grey ≈ 80% of water", absf(grey_l - 40.0) < 1.0, "grey=%.2f" % grey_l)
	_check("black ≈ 20% of water", absf(black_l - 10.0) < 1.0, "black=%.2f" % black_l)
	# Food scraps: 1.5 kg × 0.20 = 0.3 kg biomass
	var bio_kg := _tank_level(model, "bio") * 50.0
	_check("biomass scraps ≤ food consumed", bio_kg <= 1.5 + 0.05, "bio=%.3f" % bio_kg)
	_check("biomass ≈ 20% of food", absf(bio_kg - 0.3) < 0.05, "bio=%.3f" % bio_kg)


func _test_habitat_starvation() -> void:
	var g := _build_habitat_graph(1, 0.0, 0.8)
	var model = g["model"]
	var engine = g["engine"]
	engine.simulate_step_for_test(0.0, 0.0)
	engine.simulate_step_for_test(1.0, 1.0)
	var hab: Dictionary = model.get_item("hab")
	var specs: Dictionary = hab.get("specs", {}) as Dictionary
	var starved: Array = specs.get("starved_kinds", []) as Array
	_check("empty water → starved water", starved.has("water"), "starved=%s" % str(starved))
	_check("empty water → no grey invent", _tank_level(model, "grey") < 0.001,
		"grey=%.4f" % _tank_level(model, "grey"))
	# Food still available → food should still be consumed
	var fl := _tank_level(model, "food")
	_check("food still drains when water starved", fl < 0.8 - 0.001, "food=%.3f" % fl)


func _test_habitat_occupants_scale() -> void:
	var g1 := _build_habitat_graph(1, 1.0, 0.8)
	g1["engine"].simulate_step_for_test(0.0, 0.0)
	g1["engine"].simulate_step_for_test(12.0, 12.0)
	var w1 := _tank_level(g1["model"], "water")

	var g2 := _build_habitat_graph(2, 1.0, 0.8)
	g2["engine"].simulate_step_for_test(0.0, 0.0)
	g2["engine"].simulate_step_for_test(12.0, 12.0)
	var w2 := _tank_level(g2["model"], "water")

	# 2 occupants should consume ~2× → remaining level lower by ~same delta×2
	var d1 := 1.0 - w1
	var d2 := 1.0 - w2
	_check("2 occupants ≈ 2× water drain", absf(d2 - 2.0 * d1) < 0.03,
		"d1=%.3f d2=%.3f" % [d1, d2])


func _test_habitat_scrub_rewind() -> void:
	var g := _build_habitat_graph(1, 1.0, 0.8)
	var model = g["model"]
	var engine = g["engine"]
	engine.simulate_step_for_test(0.0, 0.0)
	engine.simulate_step_for_test(24.0, 24.0)
	var mid_water := _tank_level(model, "water")
	_check("scrub prep: water depleted", mid_water < 0.99, "water=%.3f" % mid_water)
	# Scrub back via timeline seek (engine read path)
	engine._read_all_tanks_at(0.0)
	var rew := _tank_level(model, "water")
	_check("scrub rewind restores water", absf(rew - 1.0) < 0.02, "rew=%.3f" % rew)
	var rew_grey := _tank_level(model, "grey")
	_check("scrub rewind clears greywater", rew_grey < 0.02, "grey=%.3f" % rew_grey)


func _test_biomass_catchment_manual_area() -> void:
	var model = GraphModelScript.new()
	var area_m2 := 10000.0
	model.add_item({
		"id": "pbi", "type": "catchment", "x": 0.0, "y": 0.0,
		"width": 110.0, "height": 90.0,
		"specs": {
			"name": "Biomass PBI", "catchment_kind": "biomass",
			"use_soi_area": false, "area_m2": area_m2,
		},
	})
	model.add_item({
		"id": "bio", "type": "resource", "x": 200.0, "y": 0.0,
		"width": 90.0, "height": 100.0,
		"specs": {
			"name": "Biomass", "resource_kind": "biomass",
			"capacity_qty": 500.0, "capacity_unit": "kg", "level": 0.0,
		},
	})
	model.add_connection({
		"id": "c_pbi", "polarity": "resource", "resource_type": "biomass",
		"source_item_id": "pbi", "source_handle_id": "output",
		"target_item_id": "bio", "target_handle_id": "input",
	})
	var engine = ResourceFlowEngineScript.new()
	engine.setup(model, null)
	var kg_h := PbiBiomassScript.biomass_kg_per_hour(area_m2, 6)
	engine.simulate_step_for_test(0.0, 0.0)
	engine.simulate_step_for_test(24.0, 24.0)
	var level := _tank_level(model, "bio")
	var expected_level := (kg_h * 24.0) / 500.0
	_check("biomass catchment fills tank", level > 0.001, "level=%.4f" % level)
	_check("biomass catchment rate ~PBI formula", absf(level - expected_level) < 0.02,
		"level=%.4f expected=%.4f" % [level, expected_level])


func _test_step_overflow_qty() -> void:
	# raw = 0.95 + 10/100 = 1.05 → 0.05 × 100 L = 5 L lost this step.
	var q := ResourceTimelineScript.step_overflow_qty(0.95, 10.0, 100.0, 1.0)
	_check("step_overflow_qty math", absf(q - 5.0) < 0.001, "got %.3f" % q)
	_check("step_overflow_qty no-op below full",
		ResourceTimelineScript.step_overflow_qty(0.2, 10.0, 100.0, 1.0) == 0.0)
	_check("step_overflow_qty invalid capacity",
		ResourceTimelineScript.step_overflow_qty(0.95, 10.0, 0.0, 1.0) == 0.0)


func _test_tank_overflow_tracking() -> void:
	# Direct timeline: capacity 10, start 0.9 full, +10 qty/h for 2 h → input 20,
	# absorbable 1.0 → 19 lost to the clamp.
	var tl = ResourceTimelineScript.new()
	tl.configure(10.0)
	tl.init_anchor(0.0, 0.9)
	tl.record_step(2.0, 10.0, 10.0, 0.0)
	_check("overflow qty accumulated", absf(tl.total_overflow_qty - 19.0) < 0.1,
		"lost=%.2f" % tl.total_overflow_qty)
	_check("is_overflowing_at end", tl.is_overflowing_at(2.0))
	tl.seek(0.0)
	_check("overflow clears on scrub-back", not tl.is_overflowing_at(0.0))

	# Engine path: unconstrained processor import dumping into a tiny near-full
	# tank still surfaces overflow (catchments are capacity-aware and no longer
	# toast-overfill by design).
	var model = GraphModelScript.new()
	model.add_item({
		"id": "truck", "type": "processor", "x": 0.0, "y": 0.0,
		"width": 110.0, "height": 90.0,
		"specs": {
			"name": "Dump", "role": "import", "counts_as_import": true,
			"requested_state": "on", "current_state": "on", "watts": 0.0,
			"inputs": [],
			"outputs": [{"kind": "biomass", "rate": 50.0, "unit": "kg/h"}],
		},
	})
	model.add_item({
		"id": "bio", "type": "resource", "x": 200.0, "y": 0.0,
		"width": 90.0, "height": 100.0,
		"specs": {
			"name": "Tiny Bio", "resource_kind": "biomass",
			"capacity_qty": 0.5, "capacity_unit": "kg", "level": 0.9,
		},
	})
	model.add_connection({
		"id": "c_over", "polarity": "resource", "resource_type": "biomass",
		"source_item_id": "truck", "source_handle_id": "res_out_0",
		"target_item_id": "bio", "target_handle_id": "input",
	})
	var engine = ResourceFlowEngineScript.new()
	engine.setup(model, null)
	engine.power_available_override = 1
	engine.simulate_step_for_test(0.0, 0.0)
	engine.simulate_step_for_test(24.0, 24.0)
	var specs: Dictionary = (model.get_item("bio").get("specs", {}) as Dictionary)
	_check("engine surfaces tank overflowing", bool(specs.get("overflowing", false)))
	_check("engine surfaces overflow_qty", float(specs.get("overflow_qty", 0.0)) > 0.0,
		"qty=%.3f" % float(specs.get("overflow_qty", 0.0)))
	engine._read_all_tanks_at(0.0)
	specs = model.get_item("bio").get("specs", {}) as Dictionary
	_check("engine overflow flag clears on scrub",
		not bool(specs.get("overflowing", true)))


func _test_unlimited_capacity_sink() -> void:
	# Unlimited sink must never block a processor as OUTPUT_FULL and never overflow.
	var model = GraphModelScript.new()
	model.add_item({
		"id": "truck", "type": "processor", "x": 0.0, "y": 0.0,
		"width": 110.0, "height": 90.0,
		"specs": {
			"name": "Dump", "role": "import", "counts_as_import": true,
			"requested_state": "on", "current_state": "on", "watts": 0.0,
			"inputs": [],
			"outputs": [{"kind": "water", "rate": 200.0, "unit": "L/h"}],
		},
	})
	model.add_item({
		"id": "sink", "type": "resource", "x": 200.0, "y": 0.0,
		"width": 90.0, "height": 100.0,
		"specs": {
			"name": "∞ Water", "resource_kind": "water",
			"capacity_qty": 100.0, "capacity_unit": "L", "level": 0.99,
			"unlimited_capacity": true,
		},
	})
	model.add_connection({
		"id": "c1", "polarity": "resource", "resource_type": "water",
		"source_item_id": "truck", "source_handle_id": "res_out_0",
		"target_item_id": "sink", "target_handle_id": "input",
	})
	var engine = ResourceFlowEngineScript.new()
	engine.setup(model, null)
	engine.power_available_override = 1
	engine.simulate_step_for_test(0.0, 0.0)
	engine.simulate_step_for_test(10.0, 10.0)
	var proc_specs: Dictionary = model.get_item("truck").get("specs", {}) as Dictionary
	_check("unlimited sink does not OUTPUT_FULL block",
		str(proc_specs.get("node_state", "")) != "blocked"
		and str(proc_specs.get("node_state_reason", "")) != "output_full",
		"state=%s reason=%s" % [proc_specs.get("node_state", ""), proc_specs.get("node_state_reason", "")])
	var sink_specs: Dictionary = model.get_item("sink").get("specs", {}) as Dictionary
	_check("unlimited sink never overflows", not bool(sink_specs.get("overflowing", false)))
	var mig := {"name": "Tank"}
	ResourceKindsScript.new().migrate_resource_specs(mig)
	_check("migrate scale_with_fill default", bool(mig.get("scale_with_fill", false)) == true)
	_check("migrate jit_outflow default", bool(mig.get("jit_outflow", true)) == false)


func _test_rain_catchment_pbi_gate() -> void:
	var model = GraphModelScript.new()
	model.add_item({
		"id": "pbi_rain", "type": "pbi", "x": -200.0, "y": 0.0,
		"width": 100.0, "height": 100.0,
		"specs": {"name": "Rain", "resource_kind": "water"},
	})
	model.add_item({
		"id": "catch", "type": "catchment", "x": 0.0, "y": 0.0,
		"width": 110.0, "height": 90.0,
		"specs": {
			"name": "Roof", "catchment_kind": "rain",
			"use_soi_area": false, "area_m2": 100.0, "runoff_coeff": 1.0,
		},
	})
	model.add_item({
		"id": "tank", "type": "resource", "x": 200.0, "y": 0.0,
		"width": 90.0, "height": 100.0,
		"specs": {
			"name": "Water", "resource_kind": "water",
			"capacity_qty": 1000.0, "capacity_unit": "L", "level": 0.0,
		},
	})
	model.add_connection({
		"id": "c_out", "polarity": "resource", "resource_type": "water",
		"source_item_id": "catch", "source_handle_id": "output",
		"target_item_id": "tank", "target_handle_id": "input",
	})
	var engine = ResourceFlowEngineScript.new()
	engine.setup(model, null)
	engine.rain_rate_override_mmh = 2.0  # 100 m² × 2 mm/h = 200 L/h
	engine.simulate_step_for_test(0.0, 0.0)
	engine.simulate_step_for_test(1.0, 1.0)
	_check("rain unwired to PBI captures nothing", _tank_level(model, "tank") < 0.001,
		"level=%.4f" % _tank_level(model, "tank"))
	model.add_connection({
		"id": "c_pbi", "polarity": "resource", "resource_type": "water",
		"source_item_id": "pbi_rain", "source_handle_id": "output",
		"target_item_id": "catch", "target_handle_id": "input",
	})
	engine.clear_timelines()
	# Reset tank level after gate failure case.
	var tspecs: Dictionary = (model.get_item("tank").get("specs", {}) as Dictionary).duplicate(true)
	tspecs["level"] = 0.0
	model.update_item("tank", {"specs": tspecs})
	engine.simulate_step_for_test(0.0, 0.0)
	engine.simulate_step_for_test(1.0, 1.0)
	var level := _tank_level(model, "tank")
	# 200 L into 1000 L = 0.20
	_check("rain PBI→catchment→tank fills", absf(level - 0.20) < 0.02,
		"level=%.4f" % level)
	var ch_handles := GraphPortServiceScript.resolved_handles(
		model.get_item("catch"), {})
	var has_in := false
	for h: Variant in ch_handles:
		if h is Dictionary and str((h as Dictionary).get("id", "")) == "input":
			has_in = true
	_check("catchment default handles include input", has_in)


func _test_rain_catchment_full_tank_stops() -> void:
	var model = GraphModelScript.new()
	model.add_item({
		"id": "pbi_rain", "type": "pbi", "x": -200.0, "y": 0.0,
		"width": 100.0, "height": 100.0,
		"specs": {"name": "Rain", "resource_kind": "water"},
	})
	model.add_item({
		"id": "catch", "type": "catchment", "x": 0.0, "y": 0.0,
		"width": 110.0, "height": 90.0,
		"specs": {
			"name": "Roof", "catchment_kind": "rain",
			"use_soi_area": false, "area_m2": 100.0, "runoff_coeff": 1.0,
		},
	})
	model.add_item({
		"id": "tank", "type": "resource", "x": 200.0, "y": 0.0,
		"width": 90.0, "height": 100.0,
		"specs": {
			"name": "Water", "resource_kind": "water",
			"capacity_qty": 100.0, "capacity_unit": "L", "level": 0.999,
		},
	})
	model.add_connection({
		"id": "c_pbi", "polarity": "resource", "resource_type": "water",
		"source_item_id": "pbi_rain", "source_handle_id": "output",
		"target_item_id": "catch", "target_handle_id": "input",
	})
	model.add_connection({
		"id": "c_out", "polarity": "resource", "resource_type": "water",
		"source_item_id": "catch", "source_handle_id": "output",
		"target_item_id": "tank", "target_handle_id": "input",
	})
	var engine = ResourceFlowEngineScript.new()
	engine.setup(model, null)
	engine.rain_rate_override_mmh = 5.0
	engine.simulate_step_for_test(0.0, 0.0)
	engine.simulate_step_for_test(5.0, 5.0)
	var specs: Dictionary = model.get_item("tank").get("specs", {}) as Dictionary
	_check("full tank does not overflow from rain catchment",
		not bool(specs.get("overflowing", false)))
	_check("full tank overflow_qty stays zero", float(specs.get("overflow_qty", 0.0)) < 0.01,
		"qty=%.3f" % float(specs.get("overflow_qty", 0.0)))


func _test_jit_tank_transfer() -> void:
	var model = GraphModelScript.new()
	model.add_item({
		"id": "up", "type": "resource", "x": 0.0, "y": 0.0,
		"width": 90.0, "height": 100.0,
		"specs": {
			"name": "Upstream", "resource_kind": "water",
			"capacity_qty": 100.0, "capacity_unit": "L", "level": 1.0,
			"jit_outflow": true,
		},
	})
	model.add_item({
		"id": "down", "type": "resource", "x": 200.0, "y": 0.0,
		"width": 90.0, "height": 100.0,
		"specs": {
			"name": "Downstream", "resource_kind": "water",
			"capacity_qty": 50.0, "capacity_unit": "L", "level": 0.0,
		},
	})
	model.add_connection({
		"id": "c_jit", "polarity": "resource", "resource_type": "water",
		"source_item_id": "up", "source_handle_id": "output",
		"target_item_id": "down", "target_handle_id": "input",
	})
	var engine = ResourceFlowEngineScript.new()
	engine.setup(model, null)
	engine.simulate_step_for_test(0.0, 0.0)
	engine.simulate_step_for_test(1.0, 1.0)
	var up_l := _tank_level(model, "up")
	var down_l := _tank_level(model, "down")
	_check("JIT fills downstream", down_l > 0.9, "down=%.3f" % down_l)
	_check("JIT drains upstream", up_l < 0.6, "up=%.3f" % up_l)
	_check("JIT no downstream overflow",
		not bool((model.get_item("down").get("specs", {}) as Dictionary).get("overflowing", false)))
	# Further time with downstream full: no overflow, levels stable-ish.
	engine.simulate_step_for_test(2.0, 1.0)
	_check("JIT stops when downstream full",
		not bool((model.get_item("down").get("specs", {}) as Dictionary).get("overflowing", false)))
	_check("JIT downstream stays ~full", _tank_level(model, "down") >= 0.99,
		"down=%.3f" % _tank_level(model, "down"))


## Water tank → AC pump → out tank, with a controller wired into power_in.
func _build_pump_graph(wire_output: bool = true) -> Dictionary:
	var model = GraphModelScript.new()
	model.add_item({
		"id": "src", "type": "resource", "x": -200.0, "y": 0.0,
		"width": 90.0, "height": 100.0,
		"specs": {
			"name": "Source", "resource_kind": "water",
			"capacity_qty": 1000.0, "capacity_unit": "L", "level": 1.0,
		},
	})
	model.add_item({
		"id": "pump", "type": "processor", "x": 0.0, "y": 0.0,
		"width": 150.0, "height": 120.0,
		"specs": {
			"name": "Pump", "watts": 500.0, "energy_source": "ac",
			"efficiency": 1.0, "current_state": "on",
			"inputs": [{"kind": "water", "rate": 10.0, "unit": "L/h"}],
			"outputs": [{"kind": "water", "rate": 10.0, "unit": "L/h"}],
		},
	})
	model.add_item({
		"id": "dst", "type": "resource", "x": 200.0, "y": 0.0,
		"width": 90.0, "height": 100.0,
		"specs": {
			"name": "Dest", "resource_kind": "water",
			"capacity_qty": 500.0, "capacity_unit": "L", "level": 0.0,
		},
	})
	model.add_item({
		"id": "ctrl", "type": "controller", "x": 0.0, "y": -200.0,
		"width": 190.0, "height": 160.0,
		"specs": {"name": "Controller"},
	})
	model.add_connection({
		"id": "c_in", "polarity": "resource", "resource_type": "water",
		"source_item_id": "src", "source_handle_id": "output",
		"target_item_id": "pump", "target_handle_id": "res_in_0",
	})
	if wire_output:
		model.add_connection({
			"id": "c_out", "polarity": "resource", "resource_type": "water",
			"source_item_id": "pump", "source_handle_id": "res_out_0",
			"target_item_id": "dst", "target_handle_id": "input",
		})
	model.add_connection({
		"id": "c_pwr", "polarity": "ac",
		"source_item_id": "ctrl", "source_handle_id": "acOutput",
		"target_item_id": "pump", "target_handle_id": "power_in",
	})
	var engine = ResourceFlowEngineScript.new()
	engine.setup(model, null)
	return {"model": model, "engine": engine}


func _test_processor_power_gating() -> void:
	# Force unpowered → nothing moves.
	var g0 := _build_pump_graph(true)
	g0["engine"].power_available_override = 0
	g0["engine"].simulate_step_for_test(0.0, 0.0)
	g0["engine"].simulate_step_for_test(24.0, 24.0)
	_check("override 0: pump idle", _tank_level(g0["model"], "dst") < 0.001,
		"dst=%.4f" % _tank_level(g0["model"], "dst"))

	# Force powered → 10 L/h × 24 h = 240 L into 500 L → 0.48.
	var g1 := _build_pump_graph(true)
	g1["engine"].power_available_override = 1
	g1["engine"].simulate_step_for_test(0.0, 0.0)
	g1["engine"].simulate_step_for_test(24.0, 24.0)
	var lvl := _tank_level(g1["model"], "dst")
	_check("override 1: pump fills dest ~0.48", absf(lvl - 0.48) < 0.02, "dst=%.4f" % lvl)

	# Default auto with no host/SolarUI → FAIL CLOSED (the audited bug).
	var g2 := _build_pump_graph(true)
	g2["engine"].simulate_step_for_test(0.0, 0.0)
	g2["engine"].simulate_step_for_test(24.0, 24.0)
	_check("no power authority: fail closed", _tank_level(g2["model"], "dst") < 0.001,
		"dst=%.4f" % _tank_level(g2["model"], "dst"))


func _test_unconnected_output_flagged() -> void:
	var g := _build_pump_graph(false)  # output port unwired
	g["engine"].power_available_override = 1
	g["engine"].simulate_step_for_test(0.0, 0.0)
	g["engine"].simulate_step_for_test(2.0, 2.0)
	var specs: Dictionary = g["model"].get_item("pump").get("specs", {}) as Dictionary
	var flagged: Array = specs.get("output_unconnected_kinds", []) as Array
	_check("unwired output flagged", flagged.has("water"), "flagged=%s" % str(flagged))
	_check("unwired output blocks flow", _tank_level(g["model"], "src") > 0.999,
		"src=%.4f" % _tank_level(g["model"], "src"))

	var g2 := _build_pump_graph(true)
	g2["engine"].power_available_override = 1
	g2["engine"].simulate_step_for_test(0.0, 0.0)
	g2["engine"].simulate_step_for_test(2.0, 2.0)
	var specs2: Dictionary = g2["model"].get_item("pump").get("specs", {}) as Dictionary
	var flagged2: Array = specs2.get("output_unconnected_kinds", []) as Array
	_check("wired output not flagged", flagged2.is_empty(), "flagged=%s" % str(flagged2))


## Continuous processors must now surface a concrete blocked state + reason
## instead of silently idling (the audited "silent return" bug).
func _test_node_state_reasons() -> void:
	# Unpowered pump → BLOCKED / no_power.
	var g0 := _build_pump_graph(true)
	g0["engine"].power_available_override = 0
	g0["engine"].simulate_step_for_test(0.0, 0.0)
	g0["engine"].simulate_step_for_test(1.0, 1.0)
	var s0: Dictionary = g0["model"].get_item("pump").get("specs", {}) as Dictionary
	_check("unpowered pump → BLOCKED", str(s0.get("node_state", "")) == GraphNodeState.BLOCKED,
		"state=%s" % str(s0.get("node_state", "")))
	_check("unpowered pump reason → no_power",
		str(s0.get("node_state_reason", "")) == GraphNodeState.REASON_NO_POWER,
		"reason=%s" % str(s0.get("node_state_reason", "")))

	# Powered + wired pump with a full source → RUNNING.
	var g1 := _build_pump_graph(true)
	g1["engine"].power_available_override = 1
	g1["engine"].simulate_step_for_test(0.0, 0.0)
	g1["engine"].simulate_step_for_test(1.0, 1.0)
	var s1: Dictionary = g1["model"].get_item("pump").get("specs", {}) as Dictionary
	_check("powered pump → RUNNING", str(s1.get("node_state", "")) == GraphNodeState.RUNNING,
		"state=%s" % str(s1.get("node_state", "")))

	# Unwired output → BLOCKED / output_unwired.
	var g2 := _build_pump_graph(false)
	g2["engine"].power_available_override = 1
	g2["engine"].simulate_step_for_test(0.0, 0.0)
	g2["engine"].simulate_step_for_test(1.0, 1.0)
	var s2: Dictionary = g2["model"].get_item("pump").get("specs", {}) as Dictionary
	_check("unwired output → BLOCKED", str(s2.get("node_state", "")) == GraphNodeState.BLOCKED,
		"state=%s" % str(s2.get("node_state", "")))
	_check("unwired output reason → output_unwired",
		str(s2.get("node_state_reason", "")) == GraphNodeState.REASON_OUTPUT_UNWIRED,
		"reason=%s" % str(s2.get("node_state_reason", "")))


func _test_habitat_node_state() -> void:
	# Empty water habitat → STARVED (unified state), still lists starved_kinds.
	var g := _build_habitat_graph(1, 0.0, 0.8)
	g["engine"].simulate_step_for_test(0.0, 0.0)
	g["engine"].simulate_step_for_test(1.0, 1.0)
	var s: Dictionary = g["model"].get_item("hab").get("specs", {}) as Dictionary
	_check("starved habitat → STARVED state",
		str(s.get("node_state", "")) == GraphNodeState.STARVED,
		"state=%s" % str(s.get("node_state", "")))

	# Fully-fed habitat → RUNNING.
	var g2 := _build_habitat_graph(1, 1.0, 0.8)
	g2["engine"].simulate_step_for_test(0.0, 0.0)
	g2["engine"].simulate_step_for_test(1.0, 1.0)
	var s2: Dictionary = g2["model"].get_item("hab").get("specs", {}) as Dictionary
	_check("fed habitat → RUNNING state",
		str(s2.get("node_state", "")) == GraphNodeState.RUNNING,
		"state=%s" % str(s2.get("node_state", "")))


## Phase 3: render_step is a pure function of time + injected AC availability,
## so a pre-render reproduces the live curve and gates on AC exactly.
func _test_render_step_determinism() -> void:
	# AC available across the render → same fill as the powered live run (~0.48).
	var g := _build_pump_graph(true)
	var eng = g["engine"]
	var steps := 24
	var dt := 1.0
	eng.render_step(0.0, 0.0, true)
	for i in range(1, steps + 1):
		eng.render_step(float(i) * dt, dt, true)
	var lvl := _tank_level(g["model"], "dst")
	_check("render_step AC-on fills dest ~0.48", absf(lvl - 0.48) < 0.03, "dst=%.4f" % lvl)

	# Same render with AC forced OFF → nothing moves (pump blocked).
	var g2 := _build_pump_graph(true)
	var eng2 = g2["engine"]
	eng2.render_step(0.0, 0.0, false)
	for i in range(1, steps + 1):
		eng2.render_step(float(i) * dt, dt, false)
	_check("render_step AC-off blocks fill", _tank_level(g2["model"], "dst") < 0.001,
		"dst=%.4f" % _tank_level(g2["model"], "dst"))

	# Determinism: a second identical render on a fresh graph matches the first.
	var g3 := _build_pump_graph(true)
	var eng3 = g3["engine"]
	eng3.render_step(0.0, 0.0, true)
	for i in range(1, steps + 1):
		eng3.render_step(float(i) * dt, dt, true)
	_check("render_step deterministic (repeatable)",
		absf(_tank_level(g3["model"], "dst") - lvl) < 1e-4,
		"a=%.5f b=%.5f" % [lvl, _tank_level(g3["model"], "dst")])

	# Scrub read: after rendering forward, seeking back reads a lower level.
	var mid := _tank_level_via_seek(eng, g["model"], 12.0, "dst")
	_check("seek_all_tanks reads mid-render level", mid > 0.001 and mid < lvl,
		"mid=%.4f full=%.4f" % [mid, lvl])


func _tank_level_via_seek(engine, model, abs_h: float, tank_id: String) -> float:
	engine.seek_all_tanks(abs_h)
	return _tank_level(model, tank_id)


## Powered processors must NOT carry a phantom "electric" resource input (which
## created a 3rd input port and shifted the real resource ports). Auto-inserted
## electric inputs are stripped and saved wires remapped on load.
## A switched-OFF processor is never "blocked": READY when powered + fed
## ("plugged in, ready"), IDLE otherwise. Only RUNNING moves resources.
func _test_processor_ready_idle() -> void:
	# OFF + powered + fed → READY, moves nothing.
	var g := _build_pump_graph(true)
	g["engine"].power_available_override = 1
	var sp: Dictionary = (g["model"].get_item("pump").get("specs", {}) as Dictionary).duplicate(true)
	sp["requested_state"] = "off"
	g["model"].update_item("pump", {"specs": sp})
	g["engine"].simulate_step_for_test(0.0, 0.0)
	g["engine"].simulate_step_for_test(1.0, 1.0)
	var s: Dictionary = g["model"].get_item("pump").get("specs", {})
	_check("off + powered + fed → READY", str(s.get("node_state", "")) == GraphNodeState.READY,
		"state=%s" % str(s.get("node_state", "")))
	_check("READY moves nothing", _tank_level(g["model"], "dst") < 0.001,
		"dst=%.4f" % _tank_level(g["model"], "dst"))

	# OFF + unpowered → IDLE (not blocked — it isn't trying to run).
	var g2 := _build_pump_graph(true)
	g2["engine"].power_available_override = 0
	var sp2: Dictionary = (g2["model"].get_item("pump").get("specs", {}) as Dictionary).duplicate(true)
	sp2["requested_state"] = "off"
	g2["model"].update_item("pump", {"specs": sp2})
	g2["engine"].simulate_step_for_test(0.0, 0.0)
	g2["engine"].simulate_step_for_test(1.0, 1.0)
	var s2: Dictionary = g2["model"].get_item("pump").get("specs", {})
	_check("off + unpowered → IDLE", str(s2.get("node_state", "")) == GraphNodeState.IDLE,
		"state=%s" % str(s2.get("node_state", "")))


## A RUNNING processor draws its watts into the AC load total (→ battery drains);
## anything else draws 0. This is the coupling that was missing (continuous
## processors previously always returned 0 W).
func _test_graph_ac_load_running_draws() -> void:
	var model = GraphModelScript.new()
	model.add_item({"id": "ctrl", "type": "controller", "specs": {"name": "Ctrl"}})
	model.add_item({"id": "proc", "type": "processor", "specs": {
		"name": "Reactor", "watts": 1200.0, "energy_source": "ac",
		"node_state": GraphNodeState.RUNNING,
	}})
	model.add_connection({
		"id": "c_pwr", "polarity": "ac",
		"source_item_id": "ctrl", "source_handle_id": "acOutput",
		"target_item_id": "proc", "target_handle_id": "power_in",
	})
	var w := GraphAcLoad.compute_watts(model, self)
	_check("RUNNING processor draws its watts", absf(w - 1200.0) < 1.0, "w=%.1f" % w)

	var sp := (model.get_item("proc").get("specs", {}) as Dictionary).duplicate(true)
	sp["node_state"] = GraphNodeState.READY
	model.update_item("proc", {"specs": sp})
	_check("READY processor draws 0", GraphAcLoad.compute_watts(model, self) < 1.0,
		"w=%.1f" % GraphAcLoad.compute_watts(model, self))


func _test_biochar_electric_input_fix() -> void:
	var model = GraphModelScript.new()
	# A SAVED graph where the old migration inserted electric(W) at index 0 and
	# biomass was therefore wired to res_in_1.
	var data := {
		"version": 5,
		"items": [
			{"id": "biomass_src", "type": "resource",
				"specs": {"resource_kind": "biomass", "capacity_qty": 100.0, "level": 1.0}},
			{"id": "reactor", "type": "processor", "specs": {
				"name": "Biochar Reactor", "watts": 1200.0, "energy_source": "ac",
				"inputs": [
					{"kind": "electric", "rate": 1200.0, "unit": "W", "mode": "continuous"},
					{"kind": "biomass", "rate": 8.0, "unit": "kg/h"},
				],
				"outputs": [{"kind": "biochar", "rate": 2.5, "unit": "kg/h"}],
			}},
		],
		"connections": [
			{"id": "c_bio", "polarity": "resource", "resource_type": "biomass",
				"source_item_id": "biomass_src", "source_handle_id": "output",
				"target_item_id": "reactor", "target_handle_id": "res_in_1"},
		],
	}
	model.deserialize(data)
	var ins: Array = (model.get_item("reactor").get("specs", {}) as Dictionary).get("inputs", []) as Array
	var has_electric := false
	for inp: Variant in ins:
		if str((inp as Dictionary).get("kind", "")) == "electric":
			has_electric = true
	_check("biochar: electric input stripped", not has_electric, "inputs=%s" % str(ins))
	_check("biochar: biomass is sole input at index 0",
		ins.size() == 1 and str((ins[0] as Dictionary).get("kind", "")) == "biomass",
		"inputs=%s" % str(ins))
	var conn := model.get_connection("c_bio")
	_check("biochar: saved biomass wire remapped res_in_1 → res_in_0",
		str(conn.get("target_handle_id", "")) == "res_in_0",
		"handle=%s" % str(conn.get("target_handle_id", "")))


func _test_biodigester_resource_kinds() -> void:
	_check("biogas kind registered", ResourceKindsScript.has_kind("biogas"))
	_check("liquid_fertilizer kind registered", ResourceKindsScript.has_kind("liquid_fertilizer"))
	_check("biogas wire compat", ResourceKindsScript.kinds_compatible("biogas", "biogas"))
	_check("liquid fertilizer compat",
			ResourceKindsScript.kinds_compatible("liquid_fertilizer", "fertilizer_effluent"))
	_check("biomass/blackwater distinct",
			not ResourceKindsScript.kinds_compatible("biomass", "blackwater"))


## Woodgas fuel tank → DC generator processor (dc_electricity output, kW
## derived from fuel throughput) → battery, wired via the +/- ports straight
## to the battery's positive/negative handles. `fuel_qty` is the fuel tank's
## total capacity (kept small in the depletion test so a 1h step drains it).
func _build_dc_generator_graph(fuel_qty: float = 1000.0, wire_dc: bool = true) -> Dictionary:
	var model = GraphModelScript.new()
	model.add_item({
		"id": "fuel", "type": "resource", "x": -200.0, "y": 0.0,
		"width": 90.0, "height": 100.0,
		"specs": {
			"name": "Woodgas", "resource_kind": "woodgas",
			"capacity_qty": fuel_qty, "capacity_unit": "m³", "level": 1.0,
		},
	})
	model.add_item({
		"id": "gen", "type": "processor", "x": 0.0, "y": 0.0,
		"width": 150.0, "height": 140.0,
		"specs": {
			"name": "Woodgas DC Generator", "watts": 0.0, "energy_source": "",
			"efficiency": 0.85, "energy_wh_per_unit": 1000.0,
			"current_output_kw": 0.0, "requested_state": "on",
			"inputs": [{"kind": "woodgas", "rate": 3.0, "unit": "m³/h"}],
			"outputs": [{"kind": "dc_electricity", "rate": 3.0, "unit": "kW"}],
		},
	})
	model.add_item({
		"id": "batt", "type": "battery", "x": 200.0, "y": 0.0,
		"width": 128.0, "height": 172.0,
		"specs": {"name": "Battery", "kwh": 10.0, "soc": 0.5},
	})
	model.add_connection({
		"id": "c_fuel", "polarity": "resource", "resource_type": "woodgas",
		"source_item_id": "fuel", "source_handle_id": "output",
		"target_item_id": "gen", "target_handle_id": "res_in_0",
	})
	if wire_dc:
		model.add_connection({
			"id": "c_pos", "polarity": "positive",
			"source_item_id": "gen", "source_handle_id": "res_out_0_pos",
			"target_item_id": "batt", "target_handle_id": "positive",
		})
		model.add_connection({
			"id": "c_neg", "polarity": "negative",
			"source_item_id": "gen", "source_handle_id": "res_out_0_neg",
			"target_item_id": "batt", "target_handle_id": "negative",
		})
	var engine = ResourceFlowEngineScript.new()
	engine.setup(model, null)
	# Passive processors still hit the generic host==null power gate in
	# _processor_has_power — force it powered like the AC pump tests do.
	engine.power_available_override = 1
	return {"model": model, "engine": engine}


func _test_dc_electricity_port_topology() -> void:
	var handles: Array = GraphHubPortsScript.default_resource_handles("dc_electricity")
	_check("dc_electricity tank has 2 ports", handles.size() == 2, "got %d" % handles.size())
	var pols: Array = []
	for h: Dictionary in handles:
		pols.append(str(h.get("polarity", "")))
	_check("dc_electricity ports are positive/negative",
		pols.has("positive") and pols.has("negative"), "pols=%s" % str(pols))
	_check("water tank still gets the generic in/out pair",
		GraphHubPortsScript.default_resource_handles("water").size() == 2)
	var water_handles: Array = GraphHubPortsScript.default_resource_handles("water")
	var water_pols: Array = []
	for h2: Dictionary in water_handles:
		water_pols.append(str(h2.get("polarity", "")))
	_check("water tank ports stay polarity=resource",
		water_pols == ["resource", "resource"], "pols=%s" % str(water_pols))

	var gen_item := {
		"type": "processor",
		"specs": {
			"energy_source": "", "watts": 0.0,
			"inputs": [], "outputs": [{"kind": "dc_electricity", "rate": 3.0}],
		},
	}
	var resolved: Array = GraphPortServiceScript.resolved_handles(gen_item, {})
	var dc_ids: Array = []
	for h3: Dictionary in resolved:
		dc_ids.append(str(h3.get("id", "")))
	_check("processor dc_electricity output → 2 ports (pos/neg)",
		dc_ids.has("res_out_0_pos") and dc_ids.has("res_out_0_neg") and not dc_ids.has("res_out_0"),
		"ids=%s" % str(dc_ids))


func _test_dc_generator_output_telemetry() -> void:
	# Small fuel tank (== one hour's post-efficiency consumption) so the
	# second step finds it empty.
	var g := _build_dc_generator_graph(2.55, true)
	var model = g["model"]
	var engine = g["engine"]
	engine.simulate_step_for_test(0.0, 0.0)
	engine.simulate_step_for_test(1.0, 1.0)
	var gen_specs: Dictionary = model.get_item("gen").get("specs", {}) as Dictionary
	# 3.0 m³/h fuel × 0.85 efficiency × 1000 Wh/m³ / 1000 = 2.55 kW.
	_check("dc generator current_output_kw ~2.55 while fed",
		absf(float(gen_specs.get("current_output_kw", 0.0)) - 2.55) < 0.02,
		"kw=%.3f" % float(gen_specs.get("current_output_kw", 0.0)))
	_check("dc generator RUNNING while fed",
		str(gen_specs.get("node_state", "")) == GraphNodeState.RUNNING,
		"state=%s" % str(gen_specs.get("node_state", "")))

	# Second step: fuel tank now empty → BLOCKED, telemetry drops to 0.
	engine.simulate_step_for_test(2.0, 1.0)
	var gen_specs2: Dictionary = model.get_item("gen").get("specs", {}) as Dictionary
	_check("dc generator current_output_kw → 0 once fuel runs out",
		float(gen_specs2.get("current_output_kw", 0.0)) < 0.001,
		"kw=%.3f" % float(gen_specs2.get("current_output_kw", 0.0)))
	_check("dc generator BLOCKED once fuel runs out",
		str(gen_specs2.get("node_state", "")) == GraphNodeState.BLOCKED,
		"state=%s" % str(gen_specs2.get("node_state", "")))


func _test_dc_power_wiring_trace() -> void:
	# Directly wired to the battery.
	var g := _build_dc_generator_graph(1000.0, true)
	g["engine"].simulate_step_for_test(0.0, 0.0)
	g["engine"].simulate_step_for_test(1.0, 1.0)
	var kw := DcPowerWiringScript.sum_graph_dc_generation_kw(g["model"])
	_check("wired dc generator counted in graph aggregation",
		absf(kw - 2.55) < 0.02, "kw=%.3f" % kw)

	# Same generator, DC ports left unwired: telemetry still computes (fuel
	# gating doesn't care about downstream wiring), but the aggregator must
	# gate on "actually reaches a battery" and report 0.
	var g2 := _build_dc_generator_graph(1000.0, false)
	g2["engine"].simulate_step_for_test(0.0, 0.0)
	g2["engine"].simulate_step_for_test(1.0, 1.0)
	var kw2 := DcPowerWiringScript.sum_graph_dc_generation_kw(g2["model"])
	_check("unwired dc generator not counted", kw2 < 0.001, "kw=%.3f" % kw2)

	# One-hop through a controller's pvPositive/pvNegative → batteryPositive/
	# batteryNegative, mirroring how a real charge controller passes PV
	# power through to the battery side.
	var model3 = GraphModelScript.new()
	model3.add_item({"id": "gen", "type": "processor", "specs": {
		"energy_source": "", "current_output_kw": 1.8,
		"outputs": [{"kind": "dc_electricity", "rate": 3.0}],
	}})
	model3.add_item({"id": "ctrl", "type": "controller", "specs": {"name": "Ctrl"}})
	model3.add_item({"id": "batt", "type": "battery", "specs": {"name": "Battery", "kwh": 10.0}})
	model3.add_connection({
		"id": "c1", "polarity": "positive",
		"source_item_id": "gen", "source_handle_id": "res_out_0_pos",
		"target_item_id": "ctrl", "target_handle_id": "pvPositive",
	})
	model3.add_connection({
		"id": "c2", "polarity": "negative",
		"source_item_id": "gen", "source_handle_id": "res_out_0_neg",
		"target_item_id": "ctrl", "target_handle_id": "pvNegative",
	})
	model3.add_connection({
		"id": "c3", "polarity": "positive",
		"source_item_id": "ctrl", "source_handle_id": "batteryPositive",
		"target_item_id": "batt", "target_handle_id": "positive",
	})
	model3.add_connection({
		"id": "c4", "polarity": "negative",
		"source_item_id": "ctrl", "source_handle_id": "batteryNegative",
		"target_item_id": "batt", "target_handle_id": "negative",
	})
	var kw3 := DcPowerWiringScript.sum_graph_dc_generation_kw(model3)
	_check("dc generator through a controller counted",
		absf(kw3 - 1.8) < 0.001, "kw=%.3f" % kw3)

	# One-hop through a dc_electricity-kind DC bus/combiner tank (fan-out —
	# continues from the tank's other port).
	var model4 = GraphModelScript.new()
	model4.add_item({"id": "gen", "type": "processor", "specs": {
		"energy_source": "", "current_output_kw": 0.9,
		"outputs": [{"kind": "dc_electricity", "rate": 3.0}],
	}})
	model4.add_item({"id": "bus", "type": "resource", "specs": {
		"name": "DC Bus", "resource_kind": "dc_electricity",
	}})
	model4.add_item({"id": "batt", "type": "battery", "specs": {"name": "Battery", "kwh": 10.0}})
	model4.add_connection({
		"id": "c1", "polarity": "positive",
		"source_item_id": "gen", "source_handle_id": "res_out_0_pos",
		"target_item_id": "bus", "target_handle_id": "positive",
	})
	model4.add_connection({
		"id": "c2", "polarity": "negative",
		"source_item_id": "gen", "source_handle_id": "res_out_0_neg",
		"target_item_id": "bus", "target_handle_id": "negative",
	})
	model4.add_connection({
		"id": "c3", "polarity": "positive",
		"source_item_id": "bus", "source_handle_id": "positive",
		"target_item_id": "batt", "target_handle_id": "positive",
	})
	model4.add_connection({
		"id": "c4", "polarity": "negative",
		"source_item_id": "bus", "source_handle_id": "negative",
		"target_item_id": "batt", "target_handle_id": "negative",
	})
	var kw4 := DcPowerWiringScript.sum_graph_dc_generation_kw(model4)
	_check("dc generator through a dc_electricity bus tank counted",
		absf(kw4 - 0.9) < 0.001, "kw=%.3f" % kw4)


func _test_dc_direct_charge_migration() -> void:
	# Old-format save: dc_direct_charge/dc_output_kw flat mechanism, no
	# dc_electricity output entry yet.
	var specs := {
		"name": "48VDC Generator", "watts": 0.0, "energy_source": "",
		"efficiency": 0.85, "energy_wh_per_unit": 0.0,
		"dc_direct_charge": true, "dc_output_kw": 3.0,
		"inputs": [{"kind": "woodgas", "rate": 3.0, "unit": "m³/h"}],
		"outputs": [],
	}
	ResourceKindsScript.new().migrate_processor_specs(specs)
	_check("migration clears dc_direct_charge", not bool(specs.get("dc_direct_charge", false)))
	_check("migration removes dc_output_kw", not specs.has("dc_output_kw"))
	var outs: Array = specs.get("outputs", []) as Array
	var dc_out: Dictionary = {}
	for o: Variant in outs:
		if o is Dictionary and str((o as Dictionary).get("kind", "")) == "dc_electricity":
			dc_out = o as Dictionary
	_check("migration adds a dc_electricity output entry", not dc_out.is_empty(),
		"outputs=%s" % str(outs))
	# Legacy peak = dc_output_kw * efficiency = 3.0 * 0.85 = 2.55 kW. New
	# formula = fuel_rate * efficiency * energy_wh_per_unit/1000, so
	# energy_wh_per_unit should back-derive to exactly 1000 Wh/m³.
	_check("migration back-derives energy_wh_per_unit to preserve peak kW",
		absf(float(specs.get("energy_wh_per_unit", 0.0)) - 1000.0) < 0.01,
		"wh_per_unit=%.2f" % float(specs.get("energy_wh_per_unit", 0.0)))

	# Idempotent: migrating an already-migrated spec doesn't double the output.
	ResourceKindsScript.new().migrate_processor_specs(specs)
	var outs2: Array = specs.get("outputs", []) as Array
	var dc_count := 0
	for o2: Variant in outs2:
		if o2 is Dictionary and str((o2 as Dictionary).get("kind", "")) == "dc_electricity":
			dc_count += 1
	_check("migration is idempotent (one dc_electricity entry)", dc_count == 1,
		"count=%d" % dc_count)

	# End-to-end: the migrated spec, run through the real engine, reproduces
	# the exact legacy peak.
	var model = GraphModelScript.new()
	model.add_item({
		"id": "fuel", "type": "resource",
		"specs": {"resource_kind": "woodgas", "capacity_qty": 1000.0, "level": 1.0},
	})
	var gen_specs3: Dictionary = specs.duplicate(true)
	gen_specs3["requested_state"] = "on"
	model.add_item({"id": "gen", "type": "processor", "specs": gen_specs3})
	model.add_connection({
		"id": "c_fuel", "polarity": "resource", "resource_type": "woodgas",
		"source_item_id": "fuel", "source_handle_id": "output",
		"target_item_id": "gen", "target_handle_id": "res_in_0",
	})
	var engine = ResourceFlowEngineScript.new()
	engine.setup(model, null)
	engine.power_available_override = 1
	engine.simulate_step_for_test(0.0, 0.0)
	engine.simulate_step_for_test(1.0, 1.0)
	var migrated_kw := float((model.get_item("gen").get("specs", {}) as Dictionary).get("current_output_kw", 0.0))
	_check("migrated generator reproduces legacy 2.55kW peak",
		absf(migrated_kw - 2.55) < 0.02, "kw=%.3f" % migrated_kw)


func _test_graph_wind_hydro_dc_aggregation() -> void:
	# Graph-only wind item (no scene_device_path) wired straight to a
	# battery's +/- ports, like a panel/wind item already does.
	var model = GraphModelScript.new()
	model.add_item({"id": "turbine", "type": "wind", "specs": {
		"name": "Turbine", "current_output_kw": 1.2,
	}})
	model.add_item({"id": "batt", "type": "battery", "specs": {"name": "Battery", "kwh": 10.0}})
	model.add_connection({
		"id": "c1", "polarity": "positive",
		"source_item_id": "turbine", "source_handle_id": "positive",
		"target_item_id": "batt", "target_handle_id": "positive",
	})
	model.add_connection({
		"id": "c2", "polarity": "negative",
		"source_item_id": "turbine", "source_handle_id": "negative",
		"target_item_id": "batt", "target_handle_id": "negative",
	})
	var kw := DcPowerWiringScript.sum_graph_dc_generation_kw(model)
	_check("graph-only wind wired to battery is counted",
		absf(kw - 1.2) < 0.001, "kw=%.3f" % kw)

	# Same turbine, but scene/HA-mirrored (scene_device_path set) — already
	# counted via SolarUI's real energy_sources group, so it must be excluded
	# here to avoid double-counting.
	var turbine_specs: Dictionary = (model.get_item("turbine").get("specs", {}) as Dictionary).duplicate(true)
	turbine_specs["scene_device_path"] = "/root/Main/SomeTurbine"
	model.update_item("turbine", {"specs": turbine_specs})
	var kw2 := DcPowerWiringScript.sum_graph_dc_generation_kw(model)
	_check("scene-mirrored wind excluded (double-count guard)", kw2 < 0.001, "kw=%.3f" % kw2)


func _test_gravity_jit_gate() -> void:
	# Uphill JIT without pump must block; with pump must flow.
	var model = GraphModelScript.new()
	model.add_item({
		"id": "hi", "type": "resource",
		"elevation_m": 10.0,
		"specs": {
			"resource_kind": "water", "capacity_qty": 100.0, "level": 1.0,
			"jit_outflow": true, "output_valve_open": true,
		},
	})
	model.add_item({
		"id": "lo", "type": "resource",
		"elevation_m": 20.0, # higher = uphill from hi
		"specs": {
			"resource_kind": "water", "capacity_qty": 100.0, "level": 0.0,
			"input_valve_open": true,
		},
	})
	model.add_connection({
		"id": "c1", "polarity": "resource", "resource_type": "water",
		"source_item_id": "hi", "source_handle_id": "output",
		"target_item_id": "lo", "target_handle_id": "input",
	})
	var engine = ResourceFlowEngineScript.new()
	engine.setup(model, null)
	engine.simulate_step_for_test(0.0, 0.0)
	engine.simulate_step_for_test(1.0, 1.0)
	var lo1: Dictionary = model.get_item("lo").get("specs", {}) as Dictionary
	_check("gravity: uphill JIT without pump does not fill",
		float(lo1.get("level", 0.0)) < 0.001, "lvl=%.4f" % float(lo1.get("level", 0.0)))
	var conn1: Dictionary = model.get_connection("c1")
	_check("gravity: needs_pump flagged", bool(conn1.get("needs_pump", false)))

	# Same topology with pump on the connection.
	var model2 = GraphModelScript.new()
	model2.add_item({
		"id": "hi", "type": "resource",
		"elevation_m": 10.0,
		"specs": {
			"resource_kind": "water", "capacity_qty": 100.0, "level": 1.0,
			"jit_outflow": true, "output_valve_open": true,
		},
	})
	model2.add_item({
		"id": "lo", "type": "resource",
		"elevation_m": 20.0,
		"specs": {
			"resource_kind": "water", "capacity_qty": 100.0, "level": 0.0,
			"input_valve_open": true,
		},
	})
	model2.add_connection({
		"id": "c1", "polarity": "resource", "resource_type": "water",
		"source_item_id": "hi", "source_handle_id": "output",
		"target_item_id": "lo", "target_handle_id": "input",
		"pump": true,
	})
	var engine2 = ResourceFlowEngineScript.new()
	engine2.setup(model2, null)
	engine2.simulate_step_for_test(0.0, 0.0)
	engine2.simulate_step_for_test(1.0, 1.0)
	var lo2: Dictionary = model2.get_item("lo").get("specs", {}) as Dictionary
	_check("gravity: uphill JIT with pump does fill",
		float(lo2.get("level", 0.0)) > 0.01, "lvl=%.4f" % float(lo2.get("level", 0.0)))

	# Downhill without pump flows.
	var model3 = GraphModelScript.new()
	model3.add_item({
		"id": "hi", "type": "resource",
		"elevation_m": 30.0,
		"specs": {
			"resource_kind": "water", "capacity_qty": 100.0, "level": 1.0,
			"jit_outflow": true, "output_valve_open": true,
		},
	})
	model3.add_item({
		"id": "lo", "type": "resource",
		"elevation_m": 10.0,
		"specs": {
			"resource_kind": "water", "capacity_qty": 100.0, "level": 0.0,
			"input_valve_open": true,
		},
	})
	model3.add_connection({
		"id": "c1", "polarity": "resource", "resource_type": "water",
		"source_item_id": "hi", "source_handle_id": "output",
		"target_item_id": "lo", "target_handle_id": "input",
	})
	var engine3 = ResourceFlowEngineScript.new()
	engine3.setup(model3, null)
	engine3.simulate_step_for_test(0.0, 0.0)
	engine3.simulate_step_for_test(1.0, 1.0)
	var lo3: Dictionary = model3.get_item("lo").get("specs", {}) as Dictionary
	_check("gravity: downhill JIT free-flows",
		float(lo3.get("level", 0.0)) > 0.01, "lvl=%.4f" % float(lo3.get("level", 0.0)))


func _test_site_layout_seed_and_clamp() -> void:
	const GraphSiteLayoutScript := preload("res://system_graph/graph_site_layout.gd")
	var items: Array = [
		{"id": "a", "type": "panel", "x": 0.0, "y": 0.0, "specs": {"wmp": 400.0}},
		{"id": "b", "type": "resource", "x": 200.0, "y": 100.0, "specs": {"capacity_qty": 200.0}},
	]
	var n: int = GraphSiteLayoutScript.seed_site_from_freeform(items, 100.0)
	_check("site seed places unplaced items", n == 2, "n=%d" % n)
	_check("site seed wrote coords on a", GraphSiteLayoutScript.has_site_coords(items[0]))
	_check("site seed wrote coords on b", GraphSiteLayoutScript.has_site_coords(items[1]))
	var clamped: Vector2 = GraphSiteLayoutScript.clamp_to_soi(Vector2(500.0, 0.0), 100.0)
	_check("site clamp length ≈ radius", absf(clamped.length() - 100.0) < 0.01,
		"len=%.3f" % clamped.length())
	var fp: Vector2 = GraphSiteLayoutScript.physical_footprint_m(items[0])
	_check("panel footprint positive", fp.x > 0.1 and fp.y > 0.1, "fp=%s" % str(fp))
	# Screen size must grow with zoom-in / shrink with zoom-out (map-locked).
	var placed := {
		"id": "p", "type": "panel",
		"site_x_m": 0.0, "site_z_m": 0.0,
		"specs": {"footprint_w_m": 2.0, "footprint_d_m": 1.0},
	}
	var sz_out: Vector2 = GraphSiteLayoutScript.site_item_screen_size(placed, 0.25)
	var sz_in: Vector2 = GraphSiteLayoutScript.site_item_screen_size(placed, 4.0)
	_check("site screen size grows with zoom-in",
		sz_in.x > sz_out.x * 8.0 and sz_in.y > sz_out.y * 8.0,
		"out=%s in=%s" % [str(sz_out), str(sz_in)])
	var expect_in := 2.0 * GraphSiteLayoutScript.SOI_PX_PER_M * 4.0
	_check("site screen size = metres × 4 px/m × zoom",
		absf(sz_in.x - expect_in) < 0.01, "sz.x=%.3f expect=%.3f" % [sz_in.x, expect_in])
	var hit_out: Vector2 = GraphSiteLayoutScript.site_item_hit_size(placed, 0.05)
	_check("site hit size floors when draw tiny",
		hit_out.x >= GraphSiteLayoutScript.MIN_SITE_HIT_PX - 0.01,
		"hit=%s" % str(hit_out))
	_check("site draw stays below hit floor when tiny",
		sz_out.x < GraphSiteLayoutScript.MIN_SITE_HIT_PX,
		"draw=%s" % str(sz_out))
	var arr := {
		"id": "arr", "type": "compound",
		"specs": {
			"compound_kind": "array",
			"array_series": 4, "array_parallel": 2, "array_panel_units": 8,
		},
	}
	var arr_fp: Vector2 = GraphSiteLayoutScript.physical_footprint_m(arr)
	_check("array compound footprint scales with panel grid",
		arr_fp.x > 5.0 and arr_fp.y > 1.5, "fp=%s" % str(arr_fp))
	_check("array compound uses rectangular plan chip",
		not GraphSiteLayoutScript.uses_circular_plan_chip(arr))
	# Hydro head derivation via elevation delta (pure math check).
	var intake_e := 120.0
	var turbine_e := 95.0
	var head := maxf(intake_e - turbine_e, 0.0)
	_check("hydro head from elevation delta", absf(head - 25.0) < 0.001, "head=%.2f" % head)
