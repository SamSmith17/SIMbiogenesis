extends SceneTree

## Headless self-test for reversible resource timelines + habitat demand.
## Run with:
##   Godot.exe.exe --headless --path . --script power_system/sources/resource_flow_selftest.gd

const ResourceTimelineScript := preload("res://core/resource_timeline.gd")
const ResourceKindsScript := preload("res://system_graph/data/resource_kinds.gd")
const ResourceFlowEngineScript := preload("res://system_graph/resource_flow_engine.gd")
const GraphModelScript := preload("res://system_graph/data/graph_model.gd")
const PbiBiomassScript := preload("res://system_graph/pbi_biomass.gd")

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
	_test_processor_power_gating()
	_test_unconnected_output_flagged()
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

	# Engine path: biomass catchment (headless-safe) overfills a tiny tank →
	# specs.overflowing surfaces on the item.
	var model = GraphModelScript.new()
	model.add_item({
		"id": "pbi", "type": "catchment", "x": 0.0, "y": 0.0,
		"width": 110.0, "height": 90.0,
		"specs": {
			"name": "Biomass PBI", "catchment_kind": "biomass",
			"use_soi_area": false, "area_m2": 10000.0,
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
		"source_item_id": "pbi", "source_handle_id": "output",
		"target_item_id": "bio", "target_handle_id": "input",
	})
	var engine = ResourceFlowEngineScript.new()
	engine.setup(model, null)
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


func _test_biodigester_resource_kinds() -> void:
	_check("biogas kind registered", ResourceKindsScript.has_kind("biogas"))
	_check("liquid_fertilizer kind registered", ResourceKindsScript.has_kind("liquid_fertilizer"))
	_check("biogas wire compat", ResourceKindsScript.kinds_compatible("biogas", "biogas"))
	_check("liquid fertilizer compat",
			ResourceKindsScript.kinds_compatible("liquid_fertilizer", "fertilizer_effluent"))
	_check("biomass/blackwater distinct",
			not ResourceKindsScript.kinds_compatible("biomass", "blackwater"))
