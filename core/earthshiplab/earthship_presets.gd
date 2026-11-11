class_name EarthshipPresets
extends RefCounted

## Built-in Earthships and the player's library (user://earthshiplab_library.json).
## "Muro di Gomme" and "Phoenix" are read off the player's own SketchUp models
## (Documents/Detail earthship.glb, earthship.glb): the detailed one's house is
## ~22 m of rooms across, rooms ~5.5 m deep behind a ~3.7 m greenhouse, floors
## ~1.15 m below its yard; the Phoenix is ~51 m across with a double glazed
## greenhouse. Room counts and widths are fitted to those overall sizes.

const LIBRARY_PATH := "user://earthshiplab_library.json"


static func builtins() -> Array:
	return [
		{"id": "simple_survival", "label": "Simple Survival (2 rooms)",
			"blurb": "The smallest Global Model: two U rooms behind a narrow greenhouse.",
			"spec": {"name": "Simple Survival", "modules": 2, "module_w": 4.3, "module_d": 4.9,
				"corridor_d": 2.4, "floor_depth": 0.6, "wall_h": 2.5, "cisterns": 1}},
		{"id": "global_model", "label": "Global Model (3 rooms)",
			"blurb": "Three rooms, a 3 m greenhouse with a planter, sunk 0.9 m.",
			"spec": {"name": "Global Model", "modules": 3}},
		{"id": "muro_di_gomme", "label": "Muro di Gomme (4 rooms)",
			"blurb": "From the detailed model: four rooms, 3.7 m greenhouse, floors 1.15 m down.",
			"spec": {"name": "Muro di Gomme", "modules": 4, "module_w": 4.45, "module_d": 5.5,
				"wall_t": 0.9, "corridor_d": 3.7, "floor_depth": 1.15, "wall_h": 2.6,
				"glazing_deg": 62.0, "entry": "centre", "cisterns": 3}},
		{"id": "phoenix", "label": "Phoenix (6 rooms, double glazed)",
			"blurb": "From the Phoenix model: a long row with a second wall of glass.",
			"spec": {"name": "Phoenix", "modules": 6, "module_w": 6.0, "module_d": 6.5,
				"wall_t": 1.0, "corridor_d": 4.5, "floor_depth": 1.0, "wall_h": 3.0,
				"inner_glazing": true, "glazing_deg": 58.0, "planter_w": 1.4,
				"entry": "right", "cisterns": 4, "cistern_l": 15000.0}},
	]


static func builtin(id: String) -> Dictionary:
	for b in builtins():
		if str(b["id"]) == id:
			return EarthshipSpec.resolve(b["spec"])
	return EarthshipSpec.default_spec()


static func load_library() -> Array:
	if not FileAccess.file_exists(LIBRARY_PATH):
		return []
	var f := FileAccess.open(LIBRARY_PATH, FileAccess.READ)
	if f == null:
		return []
	var v: Variant = JSON.parse_string(f.get_as_text())
	if v is Dictionary and (v as Dictionary).get("designs", null) is Array:
		return (v as Dictionary)["designs"]
	return []


static func save_library(designs: Array) -> void:
	var f := FileAccess.open(LIBRARY_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"version": 1, "designs": designs}, "\t"))


## Keep a design under its name (replacing one of the same name).
static func save_design(spec: Dictionary) -> void:
	var s := EarthshipSpec.to_json_safe(spec)
	var lib := load_library()
	var kept: Array = []
	for d in lib:
		if str((d as Dictionary).get("name", "")) != str(s["name"]):
			kept.append(d)
	kept.append(s)
	save_library(kept)


static func forget_design(name: String) -> void:
	var kept: Array = []
	for d in load_library():
		if str((d as Dictionary).get("name", "")) != name:
			kept.append(d)
	save_library(kept)
