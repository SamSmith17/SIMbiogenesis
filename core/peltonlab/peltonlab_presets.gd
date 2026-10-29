class_name PeltonLabPresets
extends RefCounted

## Built-in Pelton wheels and the player's library
## (user://peltonlab_library.json). Every design uses the same cup.

const LIBRARY_PATH := "user://peltonlab_library.json"


static func builtins() -> Array:
	return [
		{"id": "classic_350", "label": "Classic 350 mm, belt to a 400 W PMA",
			"blurb": "21 full-size cups, one 22 mm jet, horizontal shaft on two pillow blocks, V-belt up to a 24 V wind PMA.",
			"spec": classic_spec()},
		{"id": "pico_printed", "label": "Pico printed wheel, direct stepper",
			"blurb": "Half-size printed PETG cups on a 200 mm wheel, an 11 mm jet, a NEMA 23 stepper on a jaw coupler.",
			"spec": pico_spec()},
		{"id": "vertical_4jet", "label": "Vertical shaft, four jets, hub motor",
			"blurb": "A vertical shaft taking four small jets round a 250 mm wheel, the lid's flange bearings, geared down to a hub motor charging 24 V.",
			"spec": vertical_spec()},
		{"id": "big_pmg", "label": "Big 600 mm, two jets, 1 kW PMG",
			"blurb": "Cast aluminium cups at 1.4× on a 600 mm wheel, two jets on a low head, a straddle-mounted 40 mm shaft, a timing belt up to a 48 V PMG.",
			"spec": big_spec()},
		{"id": "alternator_high_head", "label": "High head, car alternator",
			"blurb": "A small fast wheel for a big head, belted UP to a 12 V car alternator.",
			"spec": alternator_spec()},
	]


static func classic_spec() -> Dictionary:
	return PeltonLabSpec.resolve({"name": "Classic 350"})


static func pico_spec() -> Dictionary:
	return PeltonLabSpec.resolve({
		"name": "Pico printed",
		"runner": {"cups": 22, "overall_d_mm": 200.0, "cup_width_mm": 39.5, "cup_material": "petg",
			"cup_bolts": 1, "cup_bolt": "m4"},
		"rotor": {"disc_t_mm": 3.0, "material": "alu"},
		"hub": {"shaft_d_mm": 12.0, "bolts": 4, "bolt": "m5"},
		"jets": {"count": 1, "d_mm": 11.0},
		"drive": {"type": "direct", "coupler": "jaw", "bearings": "flange", "layout": "overhung"},
		"generator": {"id": "nema23"},
		"site": {"gross_head_m": 12.0, "pipe_len_m": 40.0, "pipe_d_mm": 40.0, "battery_v": 12.0},
	})


static func vertical_spec() -> Dictionary:
	return PeltonLabSpec.resolve({
		"name": "Vertical four-jet",
		"orientation": "vertical",
		"runner": {"cups": 26, "overall_d_mm": 250.0, "cup_width_mm": 35.0, "cup_material": "alu_cast",
			"cup_bolts": 1, "cup_bolt": "m4"},
		"rotor": {"disc_t_mm": 3.0, "material": "stainless"},
		"hub": {"shaft_d_mm": 25.0, "bolts": 6, "bolt": "m5"},
		"jets": {"count": 4, "d_mm": 10.0},
		"housing": {"material": "stainless"},
		"drive": {"type": "gear", "driver_teeth": 20, "driven_teeth": 44, "module_mm": 2.0,
			"bearings": "flange", "layout": "overhung", "gen_side": "beside"},
		"generator": {"id": "hub500"},
		"site": {"gross_head_m": 16.0, "pipe_len_m": 60.0, "pipe_d_mm": 90.0, "battery_v": 24.0},
	})


static func big_spec() -> Dictionary:
	return PeltonLabSpec.resolve({
		"name": "Big 600",
		"runner": {"cups": 22, "overall_d_mm": 600.0, "cup_width_mm": 110.0, "cup_material": "alu_cast",
			"cup_bolt": "m8"},
		"rotor": {"disc_t_mm": 8.0},
		"hub": {"shaft_d_mm": 40.0, "bolts": 8, "bolt": "m10"},
		"jets": {"count": 2, "d_mm": 32.0},
		"drive": {"type": "timing", "driver_teeth": 60, "driven_teeth": 24, "layout": "straddle"},
		"generator": {"id": "pmg1k"},
		"site": {"gross_head_m": 8.0, "pipe_len_m": 60.0, "pipe_d_mm": 200.0, "battery_v": 48.0},
	})


static func alternator_spec() -> Dictionary:
	return PeltonLabSpec.resolve({
		"name": "High head alternator",
		"runner": {"cups": 24, "overall_d_mm": 260.0, "cup_width_mm": 45.0, "cup_material": "bronze",
			"cup_bolts": 1, "cup_bolt": "m5"},
		"rotor": {"disc_t_mm": 4.0, "material": "stainless"},
		"hub": {"shaft_d_mm": 25.0, "bolts": 6, "bolt": "m6"},
		"jets": {"count": 1, "d_mm": 12.0},
		"drive": {"type": "vbelt", "driver_d_mm": 200.0, "driven_d_mm": 75.0},
		"generator": {"id": "alt12"},
		"site": {"gross_head_m": 40.0, "pipe_len_m": 200.0, "pipe_d_mm": 63.0, "battery_v": 12.0},
	})


static func builtin(id: String) -> Dictionary:
	for b in builtins():
		if str(b["id"]) == id:
			return (b["spec"] as Dictionary).duplicate(true)
	return classic_spec()


static func load_library(path: String = LIBRARY_PATH) -> Array:
	if not FileAccess.file_exists(path):
		return []
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		return []
	var out: Array = []
	for e in (parsed as Dictionary).get("designs", []):
		if e is Dictionary and (e as Dictionary).get("spec", null) is Dictionary:
			out.append(e)
	return out


static func save_library(designs: Array, path: String = LIBRARY_PATH) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify({"version": 1, "designs": designs}, "  "))
	return true
