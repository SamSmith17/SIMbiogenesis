class_name GreenhousePresets
extends RefCounted

## Built-in greenhouse designs and the player's library
## (`user://greenhouselab_library.json`, {version, designs: [{id, name, spec}]}).

const LIBRARY_PATH := "user://greenhouselab_library.json"


static func builtins() -> Array:
	var out: Array = []
	var s := GreenhouseSpec.default_spec("hoop")
	s["name"] = "Backyard hoop house"
	s["width_m"] = 3.0
	s["length_m"] = 6.0
	s["eave_h_m"] = 0.0
	s["ridge_h_m"] = 2.1
	s["frame"] = "emt_1"
	s["glazing"] = {"roof": "poly_single", "walls": "poly_single", "ends": "poly_single"}
	s["vents"] = {"ridge": false, "sides": "rollup", "side_h_m": 0.8, "ends": true, "end_m2": 0.5}
	s["doors"] = {"count": 1}
	s["rain"] = {"cistern_l": 400.0}
	out.append(_entry("backyard_hoop", s, "A 10 × 20 ft hoop of EMT under one layer of poly, roll-up sides: the cheapest season extender."))
	s = GreenhouseSpec.default_spec("hoop")
	s["name"] = "Market hoop house 30 × 96"
	s["width_m"] = 9.1
	s["length_m"] = 29.3
	s["eave_h_m"] = 1.5
	s["ridge_h_m"] = 4.3
	s["frame"] = "hoop_158"
	s["vents"] = {"ridge": false, "sides": "rollup", "side_h_m": 1.2, "ends": true, "end_m2": 1.2}
	s["fans"] = {"kind": "fan_36", "count": 2}
	out.append(_entry("market_hoop", s, "The standard 30 × 96 ft high tunnel: double inflated poly, 5 ft roll-up sides, two 36\" fans."))
	s = GreenhouseSpec.default_spec("gable")
	s["name"] = "Polycarbonate gable 6 × 12"
	out.append(_entry("gable_pc", s, "An aluminium-framed gable in twin-wall polycarbonate with a ridge vent and louvred sides."))
	s = GreenhouseSpec.default_spec("lean_to")
	s["name"] = "Passive solar lean-to"
	s["mass"] = {"barrels": 16}
	out.append(_entry("solar_lean_to", s, "Glazed to the south at the winter sun's angle, an insulated masonry wall and 16 water barrels behind: it carries its own heat into the night."))
	s = GreenhouseSpec.default_spec("gothic")
	s["name"] = "Gothic arch 30 × 80"
	s["width_m"] = 9.1
	s["length_m"] = 24.4
	s["vents"] = {"ridge": true, "sides": "rollup", "side_h_m": 1.2, "ends": true}
	out.append(_entry("gothic_arch", s, "A pointed arch sheds snow better than a round hoop, and the ridge vent lets the heat out the top."))
	s = GreenhouseSpec.default_spec("lean_to")
	s["name"] = "Walipini pit greenhouse"
	s["width_m"] = 5.0
	s["length_m"] = 10.0
	s["ridge_h_m"] = 3.6
	s["front_h_m"] = 1.8
	s["eave_h_m"] = 1.8
	s["ground"] = {"sink_m": 1.8, "berm": "three", "walls": "earth_rammed"}
	s["glazing"] = {"roof": "pc_twin_8", "walls": "pc_twin_8", "ends": "stud"}
	s["mass"] = {"barrels": 8}
	s["vents"] = {"ridge": true, "ridge_w_m": 0.8, "sides": "none", "ends": true, "end_m2": 1.2}
	s["fans"] = {"kind": "fan_16", "count": 1}
	out.append(_entry("walipini", s, "Dug 1.8 m into the ground with only the south-facing roof above grade: the earth keeps it above freezing (Benson Institute's Andean walipini)."))
	s = GreenhouseSpec.default_spec("dome")
	s["name"] = "Keyhole dome 10 m"
	s["width_m"] = 10.0
	s["dome"] = {"frequency": 4, "fraction": 0.625}
	s["mass"] = {"barrels": 10}
	out.append(_entry("keyhole_dome", s, "A 4V polycarbonate dome over keyhole beds, barrels round the back."))
	s = GreenhouseSpec.default_spec("dome")
	s["name"] = "20 m geodesic greenhouse"
	s["width_m"] = 20.0
	s["dome"] = {"frequency": 6, "fraction": 0.625}
	s["glazing"] = {"roof": "pc_twin_6", "walls": "pc_twin_6", "ends": "pc_twin_6"}
	s["fans"] = {"kind": "fan_36", "count": 2}
	s["mass"] = {"barrels": 24}
	out.append(_entry("dome_20m", s, "The Closed Loop Ten greenhouse: a 66 ft 6V dome of 1\" EMT and twin-wall polycarbonate over five keyhole rings."))
	return out


static func _entry(id: String, s: Dictionary, blurb: String) -> Dictionary:
	var r := GreenhouseSpec.resolve(s)
	return {"id": id, "name": str(r["name"]), "blurb": blurb, "spec": r}


static func builtin(id: String) -> Dictionary:
	for p in builtins():
		if str(p["id"]) == id:
			return p
	return {}


static func load_library(path: String = LIBRARY_PATH) -> Array:
	if not FileAccess.file_exists(path):
		return []
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		return []
	var out: Array = []
	for d in (parsed as Dictionary).get("designs", []):
		if d is Dictionary and (d as Dictionary).get("spec") is Dictionary:
			out.append({"id": str(d.get("id", "")), "name": str(d.get("name", "Design")),
				"spec": GreenhouseSpec.resolve(d["spec"])})
	return out


static func save_library(designs: Array, path: String = LIBRARY_PATH) -> bool:
	var out: Array = []
	for d in designs:
		out.append({"id": str(d.get("id", "")), "name": str(d.get("name", "Design")),
			"spec": GreenhouseSpec.to_json_safe(d.get("spec", {}))})
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify({"version": 1, "designs": out}, "\t"))
	f.close()
	return true
