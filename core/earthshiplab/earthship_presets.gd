class_name EarthshipPresets
extends RefCounted

## Built-in Earthships and the player's library (user://earthshiplab_library.json).
## "Muro di Gomme" and "Phoenix" are read off the player's own SketchUp models
## (Documents/Detail earthship.glb, earthship.glb): the detailed one's house is
## ~22 m of rooms across, rooms ~5.5 m deep behind a ~3.7 m greenhouse, floors
## ~1.15 m below its yard; the Phoenix is ~51 m across with a double glazed
## greenhouse. Room counts and widths are fitted to those overall sizes; the
## Muro di Gomme's vigas (0.30 m, 0.585 m apart), bottle colours and its ten
## roof panels at 29° are read off the same model.

const LIBRARY_PATH := "user://earthshiplab_library.json"


static func builtins() -> Array:
	return [
		{"id": "simple_survival", "label": "Simple Survival (2 rooms)",
			"blurb": "The smallest: two open rooms behind sloped glass, an earth floor, a vegetable bed.",
			"spec": {"name": "Simple Survival", "modules": 2, "module_w": 4.3, "module_d": 4.9,
				"corridor_d": 2.4, "floor_depth": 0.6, "wall_h": 2.5, "cisterns": 1,
				"room_front": "open", "floor": "earth", "ceiling": "boards", "viga_d": 0.22,
				"bottle_ends": true, "bottle_pattern": "scatter", "bottle_colors": "amber", "bottle_density": 0.25,
				"plants": "garden", "pv_panels": 2, "skylights": false, "vents": false}},
		{"id": "global_model", "label": "Global Model (3 rooms)",
			"blurb": "Upright windows under a sloped roof, a vestibule with curved wing walls, wood and glass room fronts, solar on the roof.",
			"spec": {"name": "Global Model", "modules": 3, "glazing_style": "vertical", "entry": "centre",
				"entry_style": "vestibule", "room_front": "wood", "floor": "flagstone", "pv_panels": 9,
				"pv_tilt": 50.0, "skylights": true, "bottle_ends": true, "bottle_pattern": "clusters",
				"bottle_colors": "mixed", "bottle_density": 0.4, "plants": "mixed", "front_cut": 3.6}},
		{"id": "muro_di_gomme", "label": "Muro di Gomme (4 rooms)",
			"blurb": "From the detailed model: four rooms, bottle walls in blues and greens, ten panels at 29°, an end door.",
			"spec": {"name": "Muro di Gomme", "modules": 4, "module_w": 4.45, "module_d": 5.5,
				"wall_t": 0.9, "corridor_d": 3.7, "floor_depth": 1.15, "wall_h": 2.6,
				"glazing_deg": 62.0, "entry": "centre", "cisterns": 3, "viga_d": 0.3, "viga_spacing": 0.585,
				"room_front": "bottle", "bottle_ends": true, "bottle_colors": "blue_green", "bottle_pattern": "scatter",
				"bottle_density": 0.45, "end_door": "right", "plants": "tropical", "pv_panels": 10, "pv_tilt": 29.0,
				"skylights": true, "floor": "flagstone"}},
		{"id": "phoenix", "label": "Phoenix (6 rooms, double glazed)",
			"blurb": "From the Phoenix model: a long row with a second wall of glass and a jungle in the greenhouse.",
			"spec": {"name": "Phoenix", "modules": 6, "module_w": 6.0, "module_d": 6.5,
				"wall_t": 1.0, "corridor_d": 4.5, "floor_depth": 1.0, "wall_h": 3.0,
				"room_front": "glass", "glazing_deg": 58.0, "planter_w": 1.4,
				"entry": "right", "cisterns": 4, "cistern_l": 15000.0, "viga_d": 0.32,
				"plants": "tropical", "floor": "tile", "pv_panels": 24, "pv_tilt": 35.0, "skylights": true,
				"bottle_ends": true, "bottle_pattern": "bands", "bottle_colors": "mixed", "bottle_density": 0.3}},
		{"id": "bottle_cottage", "label": "Bottle Cottage (1 room)",
			"blurb": "One room behind a rainbow bottle wall, bottle ends, an arched end door and a grass roof.",
			"spec": {"name": "Bottle Cottage", "modules": 1, "module_w": 5.0, "module_d": 5.0,
				"corridor_d": 2.8, "floor_depth": 0.5, "wall_h": 2.6, "glazing_deg": 66.0, "cisterns": 1,
				"entry": "centre", "room_front": "bottle", "bottle_ends": true, "bottle_pattern": "arch",
				"bottle_colors": "rainbow", "bottle_density": 0.5, "end_door": "left", "plants": "tropical",
				"pv_panels": 3, "green_roof": true, "skylights": false, "floor": "earth", "berm_ends": true}},
		{"id": "taos_ridge", "label": "Taos Ridge (5 rooms)",
			"blurb": "Upright windows, amber bottle bands in every room front, a vestibule at the left end, a grass roof.",
			"spec": {"name": "Taos Ridge", "modules": 5, "module_w": 4.6, "module_d": 5.2, "corridor_d": 3.2,
				"glazing_style": "vertical", "entry": "left", "entry_style": "vestibule", "room_front": "bottle",
				"bottle_ends": false, "bottle_pattern": "bands", "bottle_colors": "amber", "bottle_density": 0.5,
				"plants": "garden", "pv_panels": 12, "pv_tilt": 40.0, "green_roof": true, "skylights": true,
				"floor": "tile", "cisterns": 4, "front_cut": 3.6, "plaster": [0.72, 0.56, 0.42]}},
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
