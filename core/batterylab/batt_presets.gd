class_name BattPresets
extends RefCounted

## Built-in battery designs, each built FROM ITS CELLS so its numbers come out
## of the design. They match the batteries in the graph library
## (`library_label` = ComponentPresets.BATTERIES' label) and the common
## forms: drop-ins, lead-acid blocks, server-rack packs, wall and rolling
## units, a DIY prismatic box and a DIY cylindrical pack.
##
## Real products are named by class ("EG4 200 Ah class"), not as copies: the
## cells and BMSs are catalog entries transcribed from data sheets, not
## teardowns of those products.

const LIBRARY_FILE := "user://batterylab_library.json"


static func _spec(name: String, form: String, cell: String, s: int, p: int,
		extra: Dictionary = {}) -> Dictionary:
	var sp := BattSpec.empty(name)
	sp["form"] = form
	sp["cell_id"] = cell
	sp["series"] = s
	sp["parallel"] = p
	BattSpec._merge(sp, extra)
	return sp


static func builtins() -> Array:
	return [
		{"id": "dropin_12v_105", "label": "12 V 105 Ah LFP drop-in (group 31)",
			"library_label": "12V 100Ah LiFePO4",
			"blurb": "Four 105 Ah prismatic cells in a group-31 case: a lead-acid replacement for vans and boats.",
			"spec": _spec("12 V 105 Ah LFP drop-in", "automotive", "eve_lf105", 4, 1,
				{"enclosure": {"group": "31"}, "compression": {"on": false}, "bms": {"id": "builtin_dropin_100"}})},
		{"id": "dropin_12v_210", "label": "12 V 210 Ah LFP drop-in (8D)",
			"library_label": "12V 200Ah LiFePO4",
			"blurb": "Two strings of four 105 Ah cells in parallel (4S2P) in an 8D case.",
			"spec": _spec("12 V 210 Ah LFP drop-in", "automotive", "eve_lf105", 4, 2,
				{"enclosure": {"group": "8D"}, "compression": {"on": false},
					"bms": {"id": "jbd_4s_100a"}})},
		{"id": "agm_12v_100", "label": "12 V 100 Ah AGM (group 31)",
			"library_label": "12V 100Ah AGM",
			"blurb": "One sealed AGM block: six 2 V cells in series inside the case.",
			"spec": _spec("12 V 100 Ah AGM", "automotive", "agm_g31_100", 1, 1)},
		{"id": "fla_6v_225", "label": "6 V 225 Ah flooded golf-cart battery",
			"library_label": "",
			"blurb": "The classic off-grid flooded battery (T-105 class): three cells, vent caps, top up with water.",
			"spec": _spec("6 V 225 Ah flooded", "automotive", "trojan_t105", 1, 1,
				{"enclosure": {"group": "GC2"}})},
		{"id": "rack_48v_105", "label": "48 V 105 Ah server-rack pack",
			"library_label": "Server Rack 48V 100Ah",
			"blurb": "Sixteen 105 Ah cells in series (16S) in a 19\" rack case with a breaker, display and CAN / RS485.",
			"spec": _spec("48 V 105 Ah rack pack", "rack", "eve_lf105", 16, 1,
				{"bms": {"id": "builtin_rack_100"}})},
		{"id": "rack_48v_50", "label": "48 V 50 Ah server-rack pack",
			"library_label": "48V 50Ah LiFePO4",
			"blurb": "A short 16S pack of 50 Ah cells: a 2.5 kWh starter rack battery.",
			"spec": _spec("48 V 50 Ah rack pack", "rack", "eve_lf50k", 16, 1,
				{"bms": {"id": "builtin_rack_100"}})},
		{"id": "rack_48v_230", "label": "48 V 230 Ah rack pack (EG4 200 Ah class)",
			"library_label": "EG4 48V 200Ah",
			"blurb": "Sixteen 230 Ah cells, 11.8 kWh, a 200 A BMS.",
			"spec": _spec("48 V 230 Ah rack pack", "rack", "eve_lf230", 16, 1,
				{"bms": {"id": "builtin_rack_200"}})},
		{"id": "wall_48v_314", "label": "48 V 314 Ah wall-mount (16 kWh)",
			"library_label": "",
			"blurb": "Sixteen 314 Ah cells upright on the wall: 16 kWh in a shallow cabinet.",
			"spec": _spec("48 V 314 Ah wall-mount", "wall", "eve_mb31", 16, 1,
				{"bms": {"id": "builtin_rack_200"}})},
		{"id": "rolling_48v_314", "label": "48 V 314 Ah rolling unit (16 kWh)",
			"library_label": "",
			"blurb": "The same 16 kWh on casters with a handle, to wheel where it is needed.",
			"spec": _spec("48 V 314 Ah rolling", "rolling", "eve_mb31", 16, 1,
				{"bms": {"id": "builtin_rack_200"}, "enclosure": {"wheels": true}})},
		{"id": "diy_16s_280", "label": "DIY 16S 280 Ah box",
			"library_label": "",
			"blurb": "Sixteen 280 Ah cells in a compression frame with a 200 A inverter BMS: the home-built 14 kWh pack.",
			"spec": _spec("DIY 16S 280 Ah", "diy", "eve_lf280k", 16, 1,
				{"bms": {"id": "jk_pb2a16s20p"}})},
		{"id": "diy_13s4p_21700", "label": "DIY 13S4P 21700 NMC pack",
			"library_label": "",
			"blurb": "Fifty-two 21700 cells in holders with nickel strip: a 48 V e-bike or tool pack.",
			"spec": _spec("DIY 13S4P 21700", "diy", "samsung_50e", 13, 4,
				{"bms": {"id": "jbd_16s_100a"}})},
	]


static func builtin(id: String) -> Dictionary:
	for b in builtins():
		if str((b as Dictionary)["id"]) == id:
			return ((b as Dictionary)["spec"] as Dictionary).duplicate(true)
	return {}


## The built-in that stands for a graph library preset ({} when none).
static func for_library_label(label: String) -> Dictionary:
	for b in builtins():
		if str((b as Dictionary)["library_label"]) == label:
			return b
	return {}


# ---------------------------------------------------------------------------
# The player's library (every world)
# ---------------------------------------------------------------------------

static func load_library(path: String = LIBRARY_FILE) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var v: Variant = JSON.parse_string(f.get_as_text())
	if v is Dictionary and (v as Dictionary).get("designs") is Dictionary:
		return v["designs"]
	return {}


static func save_to_library(id: String, spec: Dictionary, path: String = LIBRARY_FILE) -> bool:
	var lib := load_library(path)
	lib[id] = BattSpec.resolve(spec)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify({"designs": lib}, "\t"))
	return true


static func forget(id: String, path: String = LIBRARY_FILE) -> void:
	var lib := load_library(path)
	if not lib.has(id):
		return
	lib.erase(id)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"designs": lib}, "\t"))


## "51.2 V · 105 Ah · 5.4 kWh" for a gallery row.
static func size_line(spec: Dictionary) -> String:
	var d := BattDesign.solve(spec)
	var e: Dictionary = d["electrical"]
	return "%.1f V · %.0f Ah · %.1f kWh" % [float(e["v_nom"]), float(e["ah"]), float(e["wh"]) * 0.001]
