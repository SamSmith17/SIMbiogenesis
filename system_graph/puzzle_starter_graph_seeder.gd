class_name PuzzleStarterGraphSeeder
extends RefCounted

## Seeds a playable habitat subgraph (tanks + catchment + optional imports).
## Idempotent — skips if starter content or an existing habitat is present.

const STARTER_SOURCE := "puzzle_starter"
const ComponentPresetsScript := preload("res://system_graph/data/component_presets.gd")
const GraphLayoutScript := preload("res://system_graph/graph_layout.gd")


static func has_starter_content(model: GraphModel) -> bool:
	if model == null:
		return false
	for item: Dictionary in model.items:
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		if str(specs.get("source", "")) == STARTER_SOURCE:
			return true
		if str(specs.get("starter_seed", "")) == STARTER_SOURCE:
			return true
	return false


static func has_habitat(model: GraphModel) -> bool:
	if model == null:
		return false
	for item: Dictionary in model.items:
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		if str(specs.get("role", "")) == "habitat":
			return true
	return false


static func seed_graph(model: GraphModel, occupants: int = 1) -> bool:
	if model == null:
		return false
	if has_starter_content(model) or has_habitat(model):
		return false
	occupants = maxi(occupants, 1)

	var hab_specs := _habitat_specs(occupants)
	_add(model, "starter_hab", "processor", -80.0, 0.0, 150.0, 150.0, hab_specs)

	_add(model, "starter_water", "resource", -320.0, -20.0, 90.0, 100.0, {
		"name": "Potable Water", "resource_kind": "water",
		"capacity_qty": 946.0, "capacity_unit": "L", "level": 0.65, "cost": 200.0,
		"source": STARTER_SOURCE, "starter_seed": STARTER_SOURCE,
	})
	_add(model, "starter_food", "resource", -320.0, 120.0, 90.0, 100.0, {
		"name": "Food Store", "resource_kind": "food",
		"capacity_qty": 50.0, "capacity_unit": "kg", "level": 0.55, "cost": 80.0,
		"source": STARTER_SOURCE, "starter_seed": STARTER_SOURCE,
	})
	_add(model, "starter_grey", "resource", 120.0, -40.0, 90.0, 100.0, {
		"name": "Greywater", "resource_kind": "greywater",
		"capacity_qty": 400.0, "capacity_unit": "L", "level": 0.15, "cost": 60.0,
		"source": STARTER_SOURCE, "starter_seed": STARTER_SOURCE,
	})
	_add(model, "starter_black", "resource", 120.0, 90.0, 90.0, 100.0, {
		"name": "Blackwater", "resource_kind": "blackwater",
		"capacity_qty": 200.0, "capacity_unit": "L", "level": 0.1, "cost": 60.0,
		"source": STARTER_SOURCE, "starter_seed": STARTER_SOURCE,
	})
	_add(model, "starter_biomass", "resource", 280.0, 120.0, 90.0, 100.0, {
		"name": "Biomass Store", "resource_kind": "biomass",
		"capacity_qty": 500.0, "capacity_unit": "kg", "level": 0.2, "cost": 120.0,
		"source": STARTER_SOURCE, "starter_seed": STARTER_SOURCE,
	})

	_add(model, "starter_rain", "catchment", -520.0, -20.0, 110.0, 90.0, {
		"name": "SoI Rain Catchment", "catchment_kind": "rain",
		"use_soi_area": true, "area_m2": 50.0, "runoff_coeff": 0.75, "cost": 0.0,
		"source": STARTER_SOURCE, "starter_seed": STARTER_SOURCE,
	})
	_add(model, "starter_biomass_pbi", "catchment", -520.0, 120.0, 110.0, 90.0, {
		"name": "SoI Biomass PBI", "catchment_kind": "biomass",
		"use_soi_area": true, "area_m2": 100.0, "runoff_coeff": 1.0, "cost": 0.0,
		"source": STARTER_SOURCE, "starter_seed": STARTER_SOURCE,
	})
	# Rain PBI circular source — reuse the auto-seeded node if present.
	if model.get_item("pbi_rain").is_empty():
		_add(model, "pbi_rain", "pbi", -700.0, -20.0, 100.0, 100.0, {
			"name": "Rain", "resource_kind": "water",
			"source": STARTER_SOURCE, "starter_seed": STARTER_SOURCE,
		})

	_add(model, "starter_water_truck", "processor", 300.0, -120.0, 130.0, 110.0,
			_import_specs("Water Truck", "water", 200.0, "L/h"))
	_add(model, "starter_food_delivery", "processor", 300.0, 20.0, 130.0, 110.0,
			_import_specs("Food Delivery", "food", 2.0, "kg/h"))
	_add(model, "starter_grid", "processor", 300.0, 160.0, 130.0, 110.0,
			_import_specs("Grid Import", "electric", 5.0, "kWh/h"))

	_connect_resource(model, "pbi_rain", "output", "starter_rain", "input", "water")
	_connect_resource(model, "starter_rain", "output", "starter_water", "input", "water")
	_connect_resource(model, "starter_biomass_pbi", "output", "starter_biomass", "input", "biomass")
	_connect_resource(model, "starter_water", "output", "starter_hab", "res_in_0", "water")
	_connect_resource(model, "starter_food", "output", "starter_hab", "res_in_1", "food")
	_connect_resource(model, "starter_hab", "res_out_0", "starter_grey", "input", "greywater")
	_connect_resource(model, "starter_hab", "res_out_1", "starter_black", "input", "blackwater")

	var patches := GraphLayoutScript.resolve_overlaps(model.items)
	for iid: String in patches.keys():
		var pos: Vector2 = patches[iid] as Vector2
		model.update_item(iid, {"x": pos.x, "y": pos.y})

	model.changed.emit("puzzle_starter_seed")
	print("PuzzleStarterGraphSeeder: habitat + tanks + SoI catchments + import nodes")
	return true


static func _habitat_specs(occupants: int) -> Dictionary:
	for p: Dictionary in ComponentPresetsScript.HABITATS:
		if int((p.get("specs", {}) as Dictionary).get("occupants", 0)) == occupants:
			var specs: Dictionary = (p.get("specs", {}) as Dictionary).duplicate(true)
			specs["occupants"] = occupants
			specs["source"] = STARTER_SOURCE
			specs["starter_seed"] = STARTER_SOURCE
			return specs
	var specs := (ComponentPresetsScript.HABITATS[0].get("specs", {}) as Dictionary).duplicate(true)
	specs["occupants"] = occupants
	specs["source"] = STARTER_SOURCE
	specs["starter_seed"] = STARTER_SOURCE
	return specs


static func _import_specs(label: String, kind: String, rate: float, unit: String) -> Dictionary:
	return {
		"name": label, "role": "import", "counts_as_import": true,
		"watts": 0.0, "cost": 0.0, "energy_source": "",
		"efficiency": 1.0, "energy_wh_per_unit": 0.0,
		"inputs": [],
		"outputs": [{"kind": kind, "rate": rate, "unit": unit}],
		"source": STARTER_SOURCE, "starter_seed": STARTER_SOURCE,
	}


static func _add(model: GraphModel, iid: String, ty: String,
		x: float, y: float, w: float, h: float, specs: Dictionary) -> void:
	model.add_item({
		"id": iid,
		"type": ty,
		"x": x,
		"y": y,
		"width": w,
		"height": h,
		"scope_id": "root",
		"is_virtual": false,
		"specs": specs,
	})


static func _connect_resource(model: GraphModel, src_id: String, src_h: String,
		tgt_id: String, tgt_h: String, kind: String) -> void:
	model.add_connection({
		"id": "starter_%s_%s" % [src_id, tgt_id],
		"scope_id": "root",
		"polarity": "resource",
		"resource_type": kind,
		"source_item_id": src_id,
		"source_handle_id": src_h,
		"target_item_id": tgt_id,
		"target_handle_id": tgt_h,
		"waypoints": [],
		"route_3d": [],
		"conduit_type": "",
		"route_length_m": 0.0,
		"line_style": "bezier",
		"curve_tension": 1.0,
		"corner_radius": 28.0,
	})
