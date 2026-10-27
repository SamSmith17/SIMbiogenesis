class_name ToroidLabPresets
extends RefCounted

## Built-in toroid designs, and the player's library (user://toroidlab_library.json).
##
## "overview_toroid" reproduces the reference build ("Overview Toroid
## structure.glb", measured with tools/diag/glb_mesh_table_diag.gd): 24 ribs
## of 1" × 0.065" mild steel, every rib the same circle — a least-squares fit
## of the rib tubes gives a minor circle of r 1.825 m centred 2.205 m out and
## 1.352 m up, cut by the ground at R 0.93 / 3.47 m — in two 90° arcs (outer
## wall and top, coupled at 44°), twelve inner-wall arcs with a straight post
## beside each and two left open as a doorway, rings at the outer and inner
## ground, the inner top (0.92 m) and a crown ring at 77° (Ø 5.22 m, clamped
## under the ribs); a diamond-pleat canopy of 10 mm correx, one 4' × 8' sheet
## per half-bay with 2" flanges bolted three to a seam; 24 × 100 W flexible
## panels bent over the crown, 6S × 4P.

const LIBRARY_PATH := "user://toroidlab_library.json"


static func builtins() -> Array:
	return [
		{"id": "overview_toroid", "name": "Overview toroid (reference build)",
			"blurb": "The reference build: 24 ribs of 1\" mild steel, a pleated correx canopy, 24 × 100 W flexible panels in 6S × 4P.",
			"spec": overview_spec()},
		{"id": "braced_toroid", "name": "Overview toroid, braced",
			"blurb": "The reference build with X tension lines between the outer ground ring and the crown ring, and tube braces round the inner column.",
			"spec": braced_spec()},
		{"id": "small_emt", "name": "Small toroid in 3/4\" EMT",
			"blurb": "A 5 m ring of 16 ribs in 3/4\" EMT, one canopy sector per bay, 16 × 50 W panels.",
			"spec": small_spec()},
		{"id": "big_shade", "name": "Big shade toroid (12 m)",
			"blurb": "A 12 m, 36-rib toroid in 1-1/4\" tube with a 200 W panel a bay and zigzag tension lines.",
			"spec": big_spec()},
		{"id": "bare_frame", "name": "Bare frame, zigzag braced",
			"blurb": "No canopy or panels: the frame alone, with zigzag tube braces between every pair of rings.",
			"spec": bare_spec()},
	]


static func overview_spec() -> Dictionary:
	return ToroidLabSpec.resolve({
		"name": "Overview toroid",
		"torus": {"major_r_m": 2.205, "minor_r_m": 1.825, "centre_h_m": 1.352, "base_y_m": 0.04, "segments": 24,
			"inner_top_deg": -1.0, "rotation_deg": 0.5},
		"tube": {"material": "steel_1_065"},
		"ribs": {"pieces": 2, "inner_every": 2, "inner_offset": 1, "inner_skip": [17, 19], "inner_posts": true,
			"feet": false},
		"rings": {"ground_out": true, "ground_in": true, "inner_top": true, "crown": true, "crown_deg": 77.0,
			"extra_deg": [], "piece_bays": 3},
		"bracing": [],
		"canopy": {"enabled": true, "fold": "diamond", "phi_out_deg": 32.4, "phi_in_deg": 118.8, "phi_peak_deg": 74.7,
			"seam_out_mm": 19.0, "seam_in_mm": 74.0, "peak_mm": 64.0, "valley_out_mm": 367.0, "valley_in_mm": 620.0,
			"sheet": "correx_10", "flange_mm": 50.8, "bolts_per_seam": 3, "bolt": "m6", "every": 1},
		"solar": {"enabled": true, "model": "flex_100", "per_bay": 1, "every": 1, "centre_deg": 84.0,
			"standoff_mm": 6.0, "series": 6, "parallel": 4},
		"fabrication": {"units": "in", "kerf_mm": 3.0, "fitting_gap_mm": 0.0},
	})


static func braced_spec() -> Dictionary:
	var s := overview_spec()
	s["name"] = "Overview toroid, braced"
	# Rings in φ order: 0 outer ground, 1 crown, 2 inner top, 3 inner ground.
	s["bracing"] = [
		{"from": 0, "to": 1, "pattern": "x", "member": "cable", "cable": "cable_18", "every": 2, "start": 0},
		{"from": 2, "to": 3, "pattern": "zigzag", "member": "tube", "every": 2, "start": 1},
	]
	return ToroidLabSpec.resolve(s)


static func small_spec() -> Dictionary:
	var t := ToroidLabSpec.torus_from_measures(0.6, 2.5, 2.4, 0.03, 16)
	return ToroidLabSpec.resolve({
		"name": "Small EMT toroid",
		"torus": t,
		"tube": {"material": "emt_34"},
		"ribs": {"pieces": 2, "inner_every": 2, "inner_offset": 0, "inner_posts": false},
		"rings": {"crown_deg": 80.0, "piece_bays": 2},
		"canopy": {"phi_out_deg": 30.0, "phi_in_deg": 120.0, "phi_peak_deg": 76.0, "seam_out_mm": 15.0,
			"seam_in_mm": 50.0, "peak_mm": 45.0, "valley_out_mm": 250.0, "valley_in_mm": 400.0},
		"solar": {"model": "flex_50", "centre_deg": 62.0, "series": 4, "parallel": 4},
		"bracing": [{"from": 0, "to": 1, "pattern": "x", "member": "cable", "cable": "paracord", "every": 2}],
	})


static func big_spec() -> Dictionary:
	var t := ToroidLabSpec.torus_from_measures(1.6, 6.0, 4.2, 0.05, 36)
	return ToroidLabSpec.resolve({
		"name": "Big shade toroid",
		"torus": t,
		"tube": {"material": "steel_114_083"},
		"ribs": {"pieces": 3, "inner_every": 3, "inner_offset": 0, "inner_posts": true},
		"rings": {"crown_deg": 75.0, "extra_deg": [20.0], "piece_bays": 2},
		"canopy": {"enabled": true, "sheet": "correx_10_5x10", "phi_out_deg": 48.0, "phi_in_deg": 112.0,
			"phi_peak_deg": 80.0, "seam_out_mm": 25.0, "seam_in_mm": 60.0, "peak_mm": 70.0, "valley_out_mm": 380.0,
			"valley_in_mm": 520.0},
		"solar": {"model": "flex_200", "per_bay": 1, "centre_deg": 58.0, "series": 6, "parallel": 6},
		"bracing": [{"from": 0, "to": 1, "pattern": "zigzag", "member": "cable", "cable": "cable_316", "every": 1}],
	})


static func bare_spec() -> Dictionary:
	var s := overview_spec()
	s["name"] = "Bare toroid frame"
	s["canopy"]["enabled"] = false
	s["solar"]["enabled"] = false
	s["rings"]["extra_deg"] = [20.0]
	s["bracing"] = [
		{"from": 0, "to": 1, "pattern": "zigzag", "member": "tube", "every": 1},
		{"from": 1, "to": 2, "pattern": "zigzag", "member": "tube", "every": 1},
		{"from": 2, "to": 3, "pattern": "zigzag", "member": "tube", "every": 1},
	]
	return ToroidLabSpec.resolve(s)


static func builtin(id: String) -> Dictionary:
	for p in builtins():
		if str(p["id"]) == id:
			return p
	return {}


static func load_library(path: String = LIBRARY_PATH) -> Array:
	if not FileAccess.file_exists(path):
		return []
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var data: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not (data is Dictionary):
		return []
	var out: Array = []
	for d in (data as Dictionary).get("designs", []):
		if d is Dictionary and (d as Dictionary).get("spec") is Dictionary:
			out.append(d)
	return out


static func save_library(designs: Array, path: String = LIBRARY_PATH) -> bool:
	var safe: Array = []
	for d in designs:
		safe.append({"id": str(d["id"]), "name": str(d["name"]), "spec": ToroidLabSpec.to_json_safe(d["spec"])})
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify({"version": 1, "designs": safe}, "\t"))
	f.close()
	return true
