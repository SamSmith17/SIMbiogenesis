class_name FlatpackPresets
extends RefCounted

## Built-in flat-pack designs plus the player's library
## (user://flatpack_library.json: {version, designs: [{id, name, spec}]}).
##
## "PlayaTech daybed (sample)" is the GLB the designer was built from, at its
## own sizes: 1/2" ply taken as exactly 0.5", no clearance, no relief and no
## spacing between parts — what the SketchUp model draws, and what the
## selftest pins. Everything else is router-ready: real 15/32" plywood,
## clearance, dogbones and 3/8" between parts.

const LIBRARY_PATH := "user://flatpack_library.json"


static func builtins() -> Array:
	var out: Array = []
	var sample := FlatpackSpec.default_spec("sofa")
	var sp: Dictionary = sample["params"]
	sp["frame_h"] = 12.0
	sp["deck_depth"] = 36.0
	sp["arm_h"] = 24.0
	sp["brace_len"] = 24.0
	sp["brace_w"] = 12.0
	sample["material"]["nominal"] = "custom"
	sample["material"]["thickness"] = 0.5
	sample["machine"]["clearance"] = 0.0
	sample["machine"]["relief"] = "none"
	sample["machine"]["spacing"] = 0.0
	sample["machine"]["margin"] = 0.0
	sample["style"]["foot_arch"] = false
	sample["name"] = "PlayaTech daybed (sample)"
	out.append({"id": "playatech_sample", "name": "PlayaTech daybed (sample)",
		"blurb": "The sample model as drawn: 12 parts, three 4×8 sheets, no tolerances.", "spec": sample})
	var daybed := FlatpackSpec.default_spec("sofa")
	daybed["name"] = "Daybed"
	out.append({"id": "daybed", "name": "Daybed (router-ready)",
		"blurb": "The sample made cuttable: 15/32\" ply, dogbones, still three sheets.", "spec": daybed})
	var loveseat := FlatpackSpec.default_spec("sofa")
	loveseat["name"] = "Loveseat"
	loveseat["params"]["length"] = 60.0
	loveseat["params"]["cross_rails"] = 2
	loveseat["params"]["daybed"] = false
	out.append({"id": "loveseat", "name": "Loveseat", "blurb": "A 5 ft sofa, upright or reclined.",
		"spec": loveseat})
	var bench := FlatpackSpec.default_spec("bench")
	bench["name"] = "Camp bench"
	out.append({"id": "bench", "name": "Camp bench", "blurb": "4 ft, two legs, a wedged stretcher.",
		"spec": bench})
	var long_bench := FlatpackSpec.default_spec("bench")
	long_bench["name"] = "Long bench"
	long_bench["params"]["length"] = 92.0
	long_bench["params"]["legs"] = 3
	out.append({"id": "long_bench", "name": "Long bench", "blurb": "Nearly 8 ft with a middle leg.",
		"spec": long_bench})
	var back_bench := FlatpackSpec.default_spec("bench")
	back_bench["name"] = "Bench with back"
	back_bench["params"]["back"] = true
	back_bench["params"]["width"] = 16.0
	out.append({"id": "back_bench", "name": "Bench with back",
		"blurb": "The legs rise into back posts; the back rest laps onto them.", "spec": back_bench})
	var stool := FlatpackSpec.default_spec("stool")
	stool["name"] = "Camp stool"
	out.append({"id": "stool", "name": "Camp stool", "blurb": "Round top on crossed legs.", "spec": stool})
	var bar := FlatpackSpec.default_spec("stool")
	bar["name"] = "Bar stool"
	bar["params"]["height"] = 30.0
	bar["params"]["top"] = 14.0
	bar["params"]["round"] = false
	out.append({"id": "bar_stool", "name": "Bar stool", "blurb": "30\" high for a bar top.", "spec": bar})
	var table := FlatpackSpec.default_spec("table")
	table["name"] = "Camp table"
	out.append({"id": "table", "name": "Camp table", "blurb": "5 ft, panel legs and a wedged stretcher.",
		"spec": table})
	var coffee := FlatpackSpec.default_spec("coffee_table")
	coffee["name"] = "Coffee table"
	out.append({"id": "coffee", "name": "Coffee table", "blurb": "Crossed legs, slots in, no hardware.",
		"spec": coffee})
	var playa_table := FlatpackSpec.default_spec("coffee_table")
	playa_table["name"] = "Low lounge table"
	playa_table["params"]["x_legs"] = false
	playa_table["params"]["length"] = 48.0
	playa_table["params"]["height"] = 14.0
	out.append({"id": "lounge_table", "name": "Low lounge table",
		"blurb": "Panel legs and a stretcher, at cushion height.", "spec": playa_table})
	var chair := FlatpackSpec.default_spec("chair")
	chair["name"] = "Chair"
	out.append({"id": "chair", "name": "Chair", "blurb": "Two profiles, a seat and a back on tabs.",
		"spec": chair})
	var lounger := FlatpackSpec.default_spec("lounger")
	lounger["name"] = "Lounger"
	out.append({"id": "lounger", "name": "Lounger", "blurb": "Low and reclined, for the shade.",
		"spec": lounger})
	var low := FlatpackSpec.default_spec("lounger")
	low["name"] = "Ground lounger"
	low["params"]["seat_h"] = 7.0
	low["params"]["back_deg"] = 45.0
	low["params"]["seat_tilt"] = 14.0
	out.append({"id": "ground_lounger", "name": "Ground lounger",
		"blurb": "Barely off the playa, steeply reclined.", "spec": low})
	return out


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
				"spec": FlatpackSpec.resolve(d["spec"])})
	return out


static func save_library(designs: Array, path: String = LIBRARY_PATH) -> bool:
	var out: Array = []
	for d in designs:
		out.append({"id": str(d.get("id", "")), "name": str(d.get("name", "Design")),
			"spec": FlatpackSpec.to_json_safe(d.get("spec", {}))})
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify({"version": 1, "designs": out}, "\t"))
	f.close()
	return true
