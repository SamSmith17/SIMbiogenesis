class_name CspLabPresets
extends RefCounted

## Built-in concentrators — the DIY ones people really build and the
## industrial ones they are measured against — and the player's library
## (user://csplab_library.json, every world).

const LIBRARY_PATH := "user://csplab_library.json"


static func builtins() -> Array:
	return [
		{"id": "fresnel_cooker", "label": "Fresnel lens cooker (TV screen)",
			"blurb": "A 0.9 m acrylic Fresnel sheet out of a projection TV, f ≈ 0.9 m, over a black pot.",
			"spec": _s("fresnel_lens", "Fresnel lens cooker", {
				"optic": {"aperture_m": 0.9, "focal_m": 0.9, "material": "acrylic", "thickness_mm": 2.0, "square": true},
				"receiver": {"kind": "flat", "size_m": 0.08, "coating": "enamel", "h_conv": 12.0},
				"structure": {"pedestal_h_m": 1.5, "member_mm": 88.9, "wall_mm": 3.2, "drive": "worm_hand"},
				"site": {"op_temp_c": 180.0}})},
		{"id": "glass_lens", "label": "Glass burning lens 50 cm",
			"blurb": "A plano-convex low-iron glass lens: sharp near the axis, ~20 kg.",
			"spec": _s("lens", "Glass lens 50 cm", {})},
		{"id": "water_globe", "label": "Water globe 30 cm",
			"blurb": "A glass sphere filled with water: no tracking needed for a coarse spot, strong spherical aberration.",
			"spec": _s("ball_lens", "Water globe 30 cm", {"receiver": {"offset_m": 0.03}})},
		{"id": "water_lens", "label": "Hanging water lens 1 m",
			"blurb": "Water on a sagging membrane in a 1 m ring; f ≈ 3 m, ~90 kg of water to hold up.",
			"spec": _s("water_lens", "Water lens 1 m", {})},
		{"id": "diy_trough", "label": "DIY trough (aluminium sheet, copper pipe)",
			"blurb": "1.2 × 3 m bent aluminium sheet on plywood ribs, black copper pipe, no vacuum — hot water and low steam.",
			"spec": _s("parabolic_trough", "DIY trough 1.2 m", {
				"optic": {"aperture_m": 1.2, "length_m": 3.0, "focal_m": 0.3, "reflector": "aluminium"},
				"receiver": {"kind": "tube", "size_m": 0.028, "coating": "black_paint", "envelope": false, "h_conv": 12.0},
				"trace": {"slope_err_mrad": 8.0},
				"structure": {"member_mm": 60.3, "wall_mm": 2.9, "pedestal_h_m": 1.0, "pylon_spacing_m": 1.5, "drive": "actuator"},
				"site": {"op_temp_c": 110.0}})},
		{"id": "cpc_pipe", "label": "Compound parabolic trough on a pipe (string method)",
			"blurb": "The W-shaped trough drawn with a string and a speed square round a 2\" pipe: 30° acceptance, 40 % cut off, aluminium flashing with mirror film, fixed and tilted to the latitude — works without tracking and on a cloudy day.",
			"spec": _s("parabolic_trough", "CPC on a pipe", {
				"optic": {"profile": "cpc_tube", "accept_deg": 30.0, "truncate": 0.4, "length_m": 1.2, "reflector": "film"},
				"receiver": {"kind": "tube", "size_m": 0.06, "gap_mm": 3.0, "coating": "black_paint", "envelope": false, "h_conv": 8.0},
				"tracking": {"mode": "fixed", "fixed_tilt_deg": -1.0},
				"trace": {"slope_err_mrad": 8.0},
				"structure": {"member_mm": 48.3, "wall_mm": 2.6, "pedestal_h_m": 0.8, "pylon_spacing_m": 1.2, "drive": "worm_hand"},
				"site": {"op_temp_c": 60.0}})},
		{"id": "cpc_flat", "label": "Compound parabolic trough, flat absorber",
			"blurb": "The second string drawing: walls focusing a ±20° fan onto a 10 cm flat plate at the bottom, fixed and tilted to the latitude.",
			"spec": _s("parabolic_trough", "CPC flat absorber", {
				"optic": {"profile": "cpc_flat", "accept_deg": 40.0, "truncate": 0.3, "length_m": 1.2, "reflector": "film"},
				"receiver": {"kind": "flat", "size_m": 0.1, "coating": "black_paint", "h_conv": 8.0},
				"tracking": {"mode": "fixed", "fixed_tilt_deg": -1.0},
				"trace": {"slope_err_mrad": 8.0},
				"structure": {"member_mm": 48.3, "wall_mm": 2.6, "pedestal_h_m": 0.8, "pylon_spacing_m": 1.2, "drive": "worm_hand"},
				"site": {"op_temp_c": 60.0}})},
		{"id": "eurotrough", "label": "Utility trough module (EuroTrough class)",
			"blurb": "5.77 m aperture, 1.71 m focal length, 70 mm evacuated absorber (Geyer et al. 2002), one 12 m module.",
			"spec": _s("parabolic_trough", "Utility trough module", {
				"optic": {"aperture_m": 5.77, "length_m": 12.0, "focal_m": 1.71, "reflector": "silvered_glass"},
				"receiver": {"kind": "tube", "size_m": 0.07, "coating": "selective", "envelope": true},
				"trace": {"slope_err_mrad": 2.5},
				"structure": {"member_mm": 406.4, "wall_mm": 8.0, "pedestal_h_m": 3.4, "pylon_spacing_m": 12.0},
				"site": {"op_temp_c": 390.0}})},
		{"id": "dish_cooker", "label": "Parabolic dish 2 m",
			"blurb": "A 2 m silvered dish on an az-el pedestal over a small cavity: a solar furnace / steam generator.",
			"spec": _s("parabolic_dish", "Parabolic dish 2 m", {})},
		{"id": "stirling_dish", "label": "Stirling dish 8.5 m (EuroDish class)",
			"blurb": "8.5 m dish, f = 4.5 m, a 0.19 m cavity feeding a Stirling engine near 650 °C.",
			"spec": _s("parabolic_dish", "Stirling dish 8.5 m", {
				"optic": {"aperture_m": 8.5, "focal_m": 4.5, "reflector": "thin_glass"},
				"receiver": {"kind": "cavity", "size_m": 0.19, "coating": "pyromark", "h_conv": 15.0},
				"trace": {"slope_err_mrad": 2.0},
				"structure": {"member_mm": 508.0, "wall_mm": 10.0, "pedestal_h_m": 5.6},
				"site": {"op_temp_c": 650.0}})},
		{"id": "lfr_small", "label": "Linear Fresnel 10 rows",
			"blurb": "Ten 30 cm flat mirror rows bouncing onto a strip 3 m up: cheap, wind-light, cosine-hungry.",
			"spec": _s("linear_fresnel", "Linear Fresnel 10 rows", {})},
		{"id": "tower_poleward", "label": "Heliostat field, 60 × 4 m²",
			"blurb": "A small poleward field round a 15 m tower with a flat receiver.",
			"spec": _s("tower", "Heliostat field 60", {})},
		{"id": "tower_surround", "label": "Surround field, 150 heliostats",
			"blurb": "Heliostats all round a 25 m tower onto an external cylinder receiver.",
			"spec": _s("tower", "Surround field 150", {
				"optic": {"heliostats": 150, "tower_h_m": 25.0, "field": "surround", "first_row_m": 12.0, "row_spacing": 1.5},
				"receiver": {"kind": "tube", "size_m": 1.4, "height_m": 2.0},
				"structure": {"member_mm": 219.1, "wall_mm": 8.0},
				"site": {"op_temp_c": 400.0}})},
	]


static func _s(type: String, name: String, patch: Dictionary) -> Dictionary:
	var s := CspLabSpec.default_spec(type)
	s["name"] = name
	for k in patch:
		var v: Variant = patch[k]
		if v is Dictionary and s.get(k) is Dictionary:
			var dst: Dictionary = s[k]
			for kk in (v as Dictionary):
				dst[kk] = (v as Dictionary)[kk]
		else:
			s[k] = v
	return CspLabSpec.resolve(s)


static func by_id(id: String) -> Dictionary:
	for b in builtins():
		if str((b as Dictionary)["id"]) == id:
			return ((b as Dictionary)["spec"] as Dictionary).duplicate(true)
	return {}


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
	for e in ((parsed as Dictionary).get("designs", []) as Array):
		if e is Dictionary and (e as Dictionary).get("spec", null) is Dictionary:
			out.append(e)
	return out


static func save_library(designs: Array, path: String = LIBRARY_PATH) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify({"version": 1, "designs": designs}, "  "))
	return true
