class_name FarmBotPresets
extends RefCounted

## Built-in FarmBot designs, and the player's library
## (user://farmbotlab_library.json: {designs: {id: spec}}).

const LIBRARY_PATH := "user://farmbotlab_library.json"

const ORDER := ["genesis", "genesis_xl", "long_salad_12", "market_row_18", "greenhouse_keyhole_strip",
	"keyhole_dome_20m", "keyhole_small_6m"]


static func builtins() -> Dictionary:
	var out := {}
	var g := FarmBotSpec.default_spec()
	g["name"] = "FarmBot Genesis"
	g["bed"]["length_m"] = 3.0
	g["bed"]["width_m"] = 1.5
	out["genesis"] = g
	out["genesis_xl"] = FarmBotSpec.default_spec()
	var l := FarmBotSpec.default_spec()
	l["name"] = "Long salad bed (12 m)"
	l["bed"]["length_m"] = 12.0
	l["bed"]["width_m"] = 1.5
	l["crops"]["mix"] = [{"crop": "lettuce", "share": 0.35}, {"crop": "lettuce_red", "share": 0.2},
		{"crop": "romaine", "share": 0.2}, {"crop": "kale", "share": 0.15}, {"crop": "basil", "share": 0.1}]
	l["crops"]["layout"] = "interleave"
	out["long_salad_12"] = l
	var mk := FarmBotSpec.default_spec()
	mk["name"] = "Market row (18 x 2.5 m)"
	mk["bed"]["length_m"] = 18.0
	mk["bed"]["width_m"] = 2.5
	mk["bed"]["wall"] = "galvanized"
	mk["crops"]["mix"] = [{"crop": "carrot", "share": 0.25}, {"crop": "onion", "share": 0.25},
		{"crop": "chard", "share": 0.2}, {"crop": "kale", "share": 0.15}, {"crop": "lettuce", "share": 0.15}]
	mk["crops"]["layout"] = "blocks"
	mk["care"]["weed_every_days"] = 3
	out["market_row_18"] = mk
	var gh := FarmBotSpec.default_spec()
	gh["name"] = "Greenhouse strip (8 x 1.2 m)"
	gh["bed"]["length_m"] = 8.0
	gh["bed"]["width_m"] = 1.2
	gh["bed"]["wall"] = "galvanized"
	gh["crops"]["mix"] = [{"crop": "pepper_red", "share": 0.3}, {"crop": "basil", "share": 0.3},
		{"crop": "lettuce", "share": 0.4}]
	gh["crops"]["packing"] = "square"
	out["greenhouse_keyhole_strip"] = gh
	# The radial arm over the keyhole beds in a 20 m greenhouse dome: the same
	# five rings as the Closed Loop greenhouses (GrowBed's keyhole defaults).
	var kd := FarmBotSpec.default_spec()
	kd["name"] = "Keyhole greenhouse (20 m dome)"
	kd["kind"] = "radial"
	kd["crops"]["mix"] = [{"crop": "lettuce", "share": 0.2}, {"crop": "kale", "share": 0.15},
		{"crop": "chard", "share": 0.15}, {"crop": "carrot", "share": 0.15}, {"crop": "onion", "share": 0.1},
		{"crop": "pepper_red", "share": 0.1}, {"crop": "basil", "share": 0.1}, {"crop": "lettuce_red", "share": 0.05}]
	kd["crops"]["section_m"] = 2.8
	# 192 m² and ~2,700 plants is more than one arm's day at FarmBot speeds:
	# three arms share the rail, a sector each; photos every other day.
	kd["keyhole"]["arms"] = 3
	kd["care"]["photo_every_days"] = 2
	kd["care"]["weed_every_days"] = 3
	out["keyhole_dome_20m"] = kd
	var ks := kd.duplicate(true)
	ks["name"] = "Small keyhole bed (6 m)"
	ks["keyhole"]["outer_r"] = 3.0
	ks["keyhole"]["rings"] = 2
	ks["keyhole"]["centre_r"] = 0.6
	ks["crops"]["section_m"] = 1.2
	ks["keyhole"]["arms"] = 1
	ks["care"]["photo_every_days"] = 1
	ks["care"]["weed_every_days"] = 2
	out["keyhole_small_6m"] = ks
	return out


static func spec(id: String) -> Dictionary:
	var b := builtins()
	if b.has(id):
		return (b[id] as Dictionary).duplicate(true)
	var lib := load_library()
	if lib.has(id):
		return (lib[id] as Dictionary).duplicate(true)
	return FarmBotSpec.default_spec()


static func load_library() -> Dictionary:
	if not FileAccess.file_exists(LIBRARY_PATH):
		return {}
	var f := FileAccess.open(LIBRARY_PATH, FileAccess.READ)
	if f == null:
		return {}
	var v: Variant = JSON.parse_string(f.get_as_text())
	if v is Dictionary and (v as Dictionary).get("designs") is Dictionary:
		return v["designs"]
	return {}


static func save_to_library(id: String, s: Dictionary) -> bool:
	var lib := load_library()
	lib[id] = FarmBotSpec.to_json_safe(s)
	var f := FileAccess.open(LIBRARY_PATH, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify({"designs": lib}, "\t"))
	return true


static func forget(id: String) -> void:
	var lib := load_library()
	if not lib.has(id):
		return
	lib.erase(id)
	var f := FileAccess.open(LIBRARY_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"designs": lib}, "\t"))
