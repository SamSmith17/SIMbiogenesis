class_name VehiclePresets
extends RefCounted

## Built-in living vehicles: one per type, each a typical conversion with a
## lived-in interior (beds along their long axis, a galley, a toilet or a wet
## bath where there is room, the battery and tanks under the bed). Interior
## positions are in the living box's frame (VehicleSpec header): x across
## (+ = the curb / right side), z from the box's front, < 0 from its rear.
## The library at LIBRARY_PATH holds the player's own designs.

const LIBRARY_PATH := "user://vehiclelab_library.json"


static func _el(id: String, type: String, x: float, z: float, extra: Dictionary = {}) -> Dictionary:
	var e := {"id": id, "type": type, "x": x, "z": z}
	for k in extra:
		e[k] = extra[k]
	return e


static func builtins() -> Array:
	return [
		# A couple's camper: two travelling seats, both up front.
		{"id": "van", "spec": _seats(_spec("van", "Camper van (Sprinter 170)", {}, {}, [
			_el("bed", "bed", 0.0, -0.95, {"w": 1.5, "h": 0.95}),
			_el("galley", "galley", -0.66, 0.9),
			_el("fridge", "fridge", -0.68, 1.95),
			_el("bench", "bench", 0.7, 1.0, {"l": 1.0}),
			_el("toilet", "toilet", 0.68, 2.0),
			_el("cubby", "cubby", -0.75, 2.75),
			_el("battery", "battery", 0.45, -0.4),
			_el("water", "water_tank", -0.4, -0.5),
			_el("inverter", "inverter", 0.8, 2.75),
			_el("light", "light", 0.0, 2.0),
		], [
			_x("fan", "fan", "roof", 0.0, -0.3),
			_x("solar", "solar", "roof", 0.0, 1.9, {"module": "rigid_400", "rows": 1, "cols": 1}),
			_x("starlink", "starlink", "roof", 0.0, 0.7),
			_x("gland", "gland", "roof", 0.6, 1.0),
		]), 2)},
		{"id": "cargo_van", "spec": _spec("cargo_van", "Cargo van (Transit high roof)", {}, {}, [
			_el("bed", "bed", -0.48, -1.0, {"w": 0.9, "l": 1.95, "h": 0.9}),
			_el("cabinet", "cabinet", 0.72, -1.0, {"l": 1.2}),
			_el("galley", "galley", 0.68, 1.0, {"w": 0.5, "l": 1.0}),
			_el("battery", "battery", -0.48, -0.5),
			_el("water", "water_tank", -0.48, -1.5),
			_el("light", "light", 0.0, 1.8),
		])},
		{"id": "shuttle_bus", "spec": _spec("shuttle_bus", "Shuttle bus (E-450 + aerotech)", {}, {
			"stripe_on": true, "stripe": [0.15, 0.35, 0.62]}, [
			_el("bed", "bed", 0.35, -1.0, {"w": 1.4, "l": 1.95, "h": 0.75}),
			_el("bath", "shoilet", -0.72, 0.5, {"w": 0.8}),
			_el("galley", "galley", -0.8, 1.9),
			_el("fridge", "fridge", -0.82, 2.85),
			_el("dinette", "dinette", 0.67, 1.95, {"w": 0.9}),
			_el("battery", "battery", 0.3, -0.6),
			_el("water", "water_tank", 0.7, -1.5),
			_el("grey", "grey_tank", -0.1, -1.6),
			_el("black", "black_tank", -0.2, -0.9),
			_el("cubby", "cubby", 0.9, 3.0),
			_el("inverter", "inverter", -0.9, 3.6),
			_el("light", "light", 0.0, 2.4),
		], [
			_x("fan", "fan", "roof", 0.0, 0.0),
			_x("solar", "solar", "roof", 0.0, 2.1, {"module": "rigid_400", "rows": 2, "cols": 2, "portrait": true}),
			_x("awning", "awning", "right", 1.6),
		])},
		{"id": "school_bus", "spec": _spec("school_bus", "Skoolie (35 ft school bus)", {}, {
			"stripe_on": true, "stripe": [0.06, 0.06, 0.07]}, [
			_el("bed", "bed", 0.0, -1.05, {"w": 1.52, "l": 2.03, "h": 0.7}),
			_el("partition", "wall", -0.45, -2.1, {"l": 1.4, "yaw": 90.0}),
			_el("shower", "shower", 0.75, -2.5),
			_el("toilet", "toilet", -0.8, -2.6),
			_el("bunks", "bunk", -0.72, 3.2),
			_el("galley", "galley", 0.78, 2.75, {"l": 1.8}),
			_el("fridge", "fridge", 0.83, 3.92),
			_el("dinette", "dinette", 0.65, 1.0),
			_el("sofa", "sofa", -0.75, 1.2),
			_el("battery", "battery", 0.3, -0.7),
			_el("water", "water_tank", -0.4, -1.3),
			_el("grey", "grey_tank", 0.35, -1.6),
			_el("inverter", "inverter", -0.9, 4.6),
			_el("light", "light", 0.0, 2.0),
			_el("light2", "light", 0.0, 4.5),
		], [
			_x("rack", "rack", "roof", 0.0, 0.6, {"w": 2.0, "l": 6.5}),
			_x("solar", "solar", "roof", 0.0, 0.6, {"module": "rigid_400", "rows": 3, "cols": 2, "portrait": true}),
			_x("fan", "fan", "roof", 0.0, -3.4),
			_x("ladder", "ladder", "rear", 0.75),
			_x("awning", "awning", "right", 1.0, null, {"w": 4.0}),
		])},
		{"id": "step_van", "spec": _spec("step_van", "Step van (P1000)", {}, {}, [
			_el("bed", "bed", 0.0, -0.75, {"h": 0.9, "yaw": 90.0}),
			_el("workbench", "workbench", -0.7, 1.4),
			_el("cabinet", "cabinet", 0.85, 1.2),
			_el("galley", "galley", 0.8, 2.6),
			_el("toilet", "toilet", -0.8, 2.85),
			_el("battery", "battery", 0.4, -0.75),
			_el("water", "water_tank", -0.4, -0.75),
			_el("light", "light", 0.0, 2.0),
		])},
		{"id": "ambulance", "spec": _spec("ambulance", "Ambulance (Type III)",
			{"wheelbase_m": 158.0 * VehicleCatalog.IN}, {"stripe_on": true, "stripe": [0.78, 0.1, 0.1]}, [
			_el("bed", "bed", -0.6, 1.9, {"w": 0.9, "l": 1.95, "h": 0.65}),
			_el("cabinet", "cabinet", 0.9, 1.0, {"w": 0.4, "l": 1.6}),
			_el("galley", "galley", 0.8, 2.6, {"l": 1.2}),
			_el("toilet", "toilet", 0.85, 3.5),
			_el("battery", "battery", -0.6, 1.5),
			_el("water", "water_tank", -0.6, 2.4),
			_el("light", "light", 0.0, 2.0),
		])},
		{"id": "rv", "spec": _spec("rv", "RV (Class C, 24 ft)", {}, {
			"stripe_on": true, "stripe": [0.55, 0.3, 0.12]}, [
			_el("cabover", "cabover_bed", 0.0, 0.0),
			_el("bed", "bed", 0.42, -1.05, {"w": 1.37, "l": 2.03, "h": 0.65}),
			_el("bath", "shoilet", -0.73, -0.55),
			_el("galley", "galley", -0.82, 2.2, {"l": 1.2}),
			_el("fridge", "fridge", -0.85, 1.25),
			_el("dinette", "dinette", 0.65, 1.6),
			_el("battery", "battery", 0.4, -0.6),
			_el("water", "water_tank", 0.6, -1.6),
			_el("grey", "grey_tank", 0.1, -1.5),
			_el("black", "black_tank", 0.9, -0.6),
			_el("light", "light", 0.0, 2.5),
		], [
			_x("ac", "ac", "roof", 0.0, 0.8),
			_x("fan", "fan", "roof", 0.0, 2.6),
			_x("awning", "awning", "right", 0.5),
		])},
		{"id": "motorhome", "spec": _spec("motorhome", "Motorhome (Class A, 32 ft)", {}, {
			"stripe_on": true, "stripe": [0.35, 0.33, 0.3]}, [
			_el("bed", "bed", 0.0, -1.1, {"w": 1.52, "l": 2.03, "h": 0.65}),
			_el("partition", "wall", -0.4, -2.3, {"l": 1.5, "yaw": 90.0}),
			_el("bath", "shoilet", 0.75, -2.9),
			_el("galley", "galley", -0.8, 3.0, {"l": 1.8}),
			_el("fridge", "fridge", -0.85, 4.3),
			_el("dinette", "dinette", 0.7, 2.2),
			_el("sofa", "sofa", -0.8, 1.2),
			_el("battery", "battery", 0.4, -0.7),
			_el("water", "water_tank", -0.4, -1.2),
			_el("grey", "grey_tank", 0.4, -1.5),
			_el("black", "black_tank", -0.3, -0.35),
			_el("light", "light", 0.0, 3.0),
			_el("light2", "light", 0.0, 5.5),
		])},
		{"id": "box_truck", "spec": _spec("box_truck", "Box truck (16 ft, NPR)", {}, {}, [
			# The bed across the front: the roll-up rear door is the only way in.
			_el("bed", "bed", 0.0, 0.95, {"w": 1.52, "l": 2.03, "h": 0.75, "yaw": 90.0}),
			_el("galley", "galley", -0.8, 3.1),
			_el("cabinet", "cabinet", 0.9, 2.5),
			_el("toilet", "toilet", -0.85, 2.15),
			_el("battery", "battery", 0.5, 0.95),
			_el("water", "water_tank", -0.5, 0.95),
			_el("light", "light", 0.0, 2.0),
		])},
		{"id": "trailer", "spec": _body(_spec("trailer", "Travel trailer (20 ft)", {}, {
			"stripe_on": true, "stripe": [0.2, 0.45, 0.55]}, [
			_el("bed", "bed", 0.0, 1.05, {"w": 1.52, "l": 2.03, "h": 0.65}),
			_el("bath", "shoilet", -0.7, -0.55),
			_el("galley", "galley", -0.75, 3.2),
			_el("dinette", "dinette", 0.6, 3.2),
			_el("fridge", "fridge", -0.8, 4.2),
			_el("battery", "battery", 0.0, 0.8),
			_el("water", "water_tank", 0.4, 1.5),
			_el("black", "black_tank", -0.4, 1.5),
			_el("light", "light", 0.0, 3.0),
		]), {"door_at_m": 4.0})},
		{"id": "semi_container", "spec": _spec("semi_container", "Semi + 40 ft container home", {}, {}, [
			_el("bed", "bed", 0.0, 1.1, {"w": 1.52, "l": 2.03, "h": 0.65, "yaw": 90.0}),
			_el("partition", "wall", 0.38, 2.4, {"l": 1.5, "yaw": 90.0}),
			_el("shower", "shower", -0.75, 3.0),
			_el("toilet", "toilet", -0.8, 3.8),
			_el("galley", "galley", 0.8, 5.0, {"l": 2.2}),
			_el("fridge", "fridge", 0.85, 6.5),
			_el("dinette", "dinette", -0.6, 6.0),
			_el("sofa", "sofa", -0.75, 8.5),
			_el("bunks", "bunk", 0.75, 9.0),
			_el("workbench", "workbench", 0.75, -0.9),
			_el("battery", "battery", 0.0, 0.7),
			_el("water", "water_tank", 0.5, 1.5),
			_el("light", "light", 0.0, 4.0),
			_el("light2", "light", 0.0, 8.0),
		])},
	]


static func _spec(type: String, name: String, chassis: Dictionary, paint: Dictionary,
		elements: Array, exterior: Array = []) -> Dictionary:
	var s := VehicleSpec.default_spec(type)
	s["name"] = name
	s["chassis"] = chassis
	s["paint"] = paint
	s["interior"] = {"elements": elements}
	s["exterior"] = {"elements": exterior}
	return s


## The same spec with body overrides (VehicleSpec.BODY_KEYS).
static func _body(s: Dictionary, over: Dictionary) -> Dictionary:
	s["body"] = over
	return s


## The same spec with its travelling seats set (incl. the driver).
static func _seats(s: Dictionary, n: int) -> Dictionary:
	s["seats"] = n
	return s


## An exterior item: type, face, (u, v) on it and its own fields
## (VehicleExterior). Omit u / v and it centres itself on the face.
static func _x(id: String, type: String, face: String, u: Variant = null, v: Variant = null,
		extra: Dictionary = {}) -> Dictionary:
	var e := {"id": id, "type": type, "face": face}
	if u != null:
		e["u"] = u
	if v != null:
		e["v"] = v
	for k in extra:
		e[k] = extra[k]
	return e


static func builtin(id: String) -> Dictionary:
	for b in builtins():
		if str((b as Dictionary)["id"]) == id:
			return ((b as Dictionary)["spec"] as Dictionary).duplicate(true)
	return VehicleSpec.default_spec(id if VehicleCatalog.TYPES.has(id) else "van")


static func load_library() -> Array:
	if not FileAccess.file_exists(LIBRARY_PATH):
		return []
	var f := FileAccess.open(LIBRARY_PATH, FileAccess.READ)
	if f == null:
		return []
	var data: Variant = JSON.parse_string(f.get_as_text())
	if data is Dictionary and (data as Dictionary).get("designs", []) is Array:
		return (data as Dictionary)["designs"]
	return []


static func save_library(designs: Array) -> bool:
	var f := FileAccess.open(LIBRARY_PATH, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify({"version": 1, "designs": designs}, "\t"))
	return true
