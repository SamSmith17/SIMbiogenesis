class_name CampTemplates
extends RefCounted

## What a festival CAMP is on the systems graph: a super-node stamped from a
## template keyed by its placement style, holding the camp's habitat (pop-
## driven), its stores, and BOUNDARY nodes for every loop the camp does not
## close itself — water and food come in, greywater and blackwater go out.
## The boundary nodes are promoted to the compound's ports, so at festival
## level a camp reads as "wants water in, gives blackwater out" and can be
## wired to a depot, a pump-out service or a neighbour's surplus.
##
## Camps are stamped and then detached (`GraphComponentDefs.make_unique`):
## editing one camp must not edit fifty, which is what the SketchUp-style
## definition sync would do. A player who WANTS lock-step camps can still
## "Save as Component" one and re-stamp it.
##
## Pure data in the builtin-definition shape (see
## ComponentPresets._def_hybrid_inverter): `subgraph.items` with local ids,
## `connections`, `exposed_ports`. Per-instance numbers (occupants, home
## position, lot id) are written onto the realized items afterwards.

const DEF_PREFIX := "camp_"
## Stores per PERSON, scaled by headcount at stamping (water 50 L/day).
## Store sizes come from CampProvisioning (rates per person × the preset's
## days × margin) so the templates, the inspector's Provision action and the
## selftest can never disagree about how long a camp lasts.

const STYLE_LABELS := {
	"mixed": "Mixed camp", "rv_park": "RV camp", "tent_village": "Tent village",
	"car_camping": "Car camp", "theme_camp": "Theme camp", "glamping": "Glamping",
}


static func def_id_for(style: String, preset: String = "") -> String:
	var sid := style if STYLE_LABELS.has(style) else "mixed"
	return DEF_PREFIX + sid + ("" if preset.is_empty() or preset == "weekend" else "_" + preset)


## The definition for a style, sized for `headcount` people (stores scale
## with the camp; the layout is the same for every style in this round — the
## style's difference, its POWER, arrives with the per-camp energy phase).
## `preset` is a CampProvisioning preset id: how many days the camp's
## stores last before anything has to be wired in (default a weekend).
static func definition(style: String, headcount: int, preset: String = "weekend") -> Dictionary:
	var n := maxi(headcount, 1)
	var sid := style if STYLE_LABELS.has(style) else "mixed"
	var pid := preset if CampProvisioning.PRESETS.has(preset) else "weekend"
	var def_id := def_id_for(sid, pid)
	var sup := CampProvisioning.supply(n, pid)
	return {
		"id": def_id, "name": str(STYLE_LABELS[sid]), "icon": "⛺", "rev": 1,
		"width": 220.0, "height": 150.0,
		"specs": {
			"summary": "%d people · %s" % [n, STYLE_LABELS[sid]],
			"camp_template": sid,
			"camp_provision": pid,
		},
		"subgraph": {
			"items": [
				{"local_id": "hab", "type": "processor", "dx": 0.0, "dy": 0.0,
					"specs": _habitat_specs(n)},
				{"local_id": "water", "type": "resource", "dx": -260.0, "dy": -200.0,
					"specs": _tank("Water Tank", "water", "L", float(sup["water"]["capacity"]), 1.0)},
				{"local_id": "food", "type": "resource", "dx": -60.0, "dy": -200.0,
					"specs": _tank("Food Store", "food", "kg", float(sup["food"]["capacity"]), 1.0)},
				{"local_id": "biomass", "type": "resource", "dx": 140.0, "dy": -200.0,
					"specs": _tank("Firewood", "biomass", "kg", float(sup["biomass"]["capacity"]), 1.0)},
				{"local_id": "grey", "type": "resource", "dx": -160.0, "dy": 220.0,
					"specs": _tank("Greywater Tank", "greywater", "L", float(sup["greywater"]["capacity"]), 0.0)},
				{"local_id": "black", "type": "resource", "dx": 60.0, "dy": 220.0,
					"specs": _tank("Blackwater Tank", "blackwater", "L", float(sup["blackwater"]["capacity"]), 0.0)},
			],
			"connections": [
				_res("water", "output", "hab", "res_in_0", "water"),
				_res("food", "output", "hab", "res_in_1", "food"),
				_res("biomass", "output", "hab", "res_in_3", "biomass"),
				_res("hab", "res_out_0", "grey", "input", "greywater"),
				_res("hab", "res_out_1", "black", "input", "blackwater"),
			],
			# The open loops, as the compound's ports: fill the stores from the
			# top, empty the waste from the bottom.
			"exposed_ports": [
				{"handle_id": "water_in", "child": "water", "child_handle": "input",
					"direction": "in", "polarity": "resource", "kind": "water", "label": "Water in", "face": "top"},
				{"handle_id": "food_in", "child": "food", "child_handle": "input",
					"direction": "in", "polarity": "resource", "kind": "food", "label": "Food in", "face": "top"},
				{"handle_id": "biomass_in", "child": "biomass", "child_handle": "input",
					"direction": "in", "polarity": "resource", "kind": "biomass", "label": "Firewood in", "face": "top"},
				{"handle_id": "grey_out", "child": "grey", "child_handle": "output",
					"direction": "out", "polarity": "resource", "kind": "greywater", "label": "Greywater out", "face": "bottom"},
				{"handle_id": "black_out", "child": "black", "child_handle": "output",
					"direction": "out", "polarity": "resource", "kind": "blackwater", "label": "Blackwater out", "face": "bottom"},
			],
		},
	}


static func _habitat_specs(n: int) -> Dictionary:
	return {
		"name": "Camp", "role": "habitat", "occupants": n, "pop_driven": true,
		"pop_routine": NpcRoutine.festival_day().to_array(),
		"watts": 0.0, "cost": 0.0, "energy_source": "", "efficiency": 1.0,
		"energy_wh_per_unit": 0.0,
		"inputs": [
			{"kind": "water", "rate": 2.083, "unit": "L/h"},
			{"kind": "food", "rate": 0.0625, "unit": "kg/h"},
			{"kind": "meal", "rate": 0.0, "unit": "meals/h"},
			{"kind": "biomass", "rate": 0.0, "unit": "kg/h"},
		],
		"outputs": [
			{"kind": "greywater", "rate": 1.666, "unit": "L/h"},
			{"kind": "blackwater", "rate": 0.417, "unit": "L/h"},
			{"kind": "biomass", "rate": 0.0125, "unit": "kg/h"},
		],
	}


static func _tank(name: String, kind: String, unit: String, cap: float, level: float) -> Dictionary:
	return {"name": name, "resource_kind": kind, "capacity": "%.0f %s" % [cap, unit],
		"capacity_qty": cap, "capacity_unit": unit, "level": level, "cost": 0.0}


static func _res(src: String, sh: String, dst: String, dh: String, kind: String) -> Dictionary:
	return {"source": src, "source_handle": sh, "target": dst, "target_handle": dh,
		"polarity": "resource", "resource_type": kind}
