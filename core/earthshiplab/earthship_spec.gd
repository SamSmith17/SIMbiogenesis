class_name EarthshipSpec
extends RefCounted

## An Earthship as numbers (pure). The "Global Model" pattern: a row of
## U-shaped rooms whose tyre walls are bermed on three sides, opening onto a
## greenhouse corridor behind sloped glazing that faces the equator.
##
## Frame (metres): x along the row (0 = its middle), +z toward the glazing
## (the front; at yaw 0 that is south), y = 0 at GRADE. Rooms sit
## `floor_depth` below grade.

const MAX_MODULES := 8
const KEY := "earthship_spec"
const ENTRY := ["left", "centre", "right"]
## The greenhouse front: "sloped" = one sheet of glazing from the kneewall
## to the roof (the classic Earthship); "vertical" = upright windows under a
## sloped greenhouse roof (the newer Global Model, Taos 2010s).
const GLAZING_STYLES := ["sloped", "vertical"]
## Between each room and the greenhouse.
const ROOM_FRONTS := ["open", "wood", "glass", "bottle"]
const ENTRY_STYLES := ["alcove", "vestibule"]
const BOTTLE_PATTERNS := ["scatter", "bands", "arch", "clusters"]
const BOTTLE_PALETTES := ["mixed", "blue_green", "amber", "rainbow"]
const END_DOORS := ["none", "left", "right", "both"]
const PLANTS := ["tropical", "garden", "mixed", "none"]
const FLOORS := ["flagstone", "earth", "tile"]
const CEILINGS := ["boards", "plaster"]

## Sources for the defaults:
##  - Reynolds, "Earthship Vol. 1" (1990): U-module ~16' (4.9 m) wide inside,
##    rammed-tyre walls ~0.75 m, 2.4-2.7 m inside, sunk 0.6-1.2 m.
##  - Glazing at right angles to the winter-solstice noon sun:
##    angle above horizontal = latitude + 23.44 (EarthshipLab.glazing_for_lat).
static func default_spec() -> Dictionary:
	return {
		"name": "Global Model",
		"modules": 3,
		"module_w": 4.9,
		"module_d": 5.5,
		"wall_t": 0.9,
		"wall_h": 2.6,
		"floor_depth": 0.9,
		"corridor_d": 3.0,
		"glazing_deg": 60.0,
		"sill_h": 0.75,
		"inner_glazing": false,
		"planter_w": 1.0,
		"planter_h": 0.55,
		"roof_t": 0.45,
		"berm_run": 1.6,
		"berm_ends": true,
		"entry": "left",
		"front_cut": 2.4,
		"ramp": true,
		"cisterns": 2,
		"cistern_l": 13000.0,
		"plaster": [0.78, 0.66, 0.5],
		"trim": [0.43, 0.29, 0.18],
		# The look (2026-11-11 pass, from Earthship Biotecture photos and the
		# player's detail model).
		"glazing_style": "sloped",
		"vents": true,
		"room_front": "wood",
		"entry_style": "alcove",
		"viga_d": 0.25,
		"viga_spacing": 0.6,
		"ceiling": "boards",
		"floor": "flagstone",
		"bottle_ends": true,
		"bottle_pattern": "scatter",
		"bottle_colors": "mixed",
		"bottle_density": 0.35,
		"end_door": "none",
		"plants": "mixed",
		"pv_panels": 6,
		"pv_tilt": 45.0,
		"pv_watts": 400.0,
		"skylights": true,
		"green_roof": false,
	}


static func _f(d: Dictionary, k: String, dv: float) -> float:
	var v: Variant = d.get(k, dv)
	return float(v) if (v is float or v is int) else dv


static func resolve(spec_in: Variant) -> Dictionary:
	var s := default_spec()
	if spec_in is Dictionary:
		for k in (spec_in as Dictionary).keys():
			s[k] = (spec_in as Dictionary)[k]
	s["modules"] = clampi(int(_f(s, "modules", 3)), 1, MAX_MODULES)
	s["module_w"] = clampf(_f(s, "module_w", 4.9), 2.0, 8.0)
	s["module_d"] = clampf(_f(s, "module_d", 5.5), 2.0, 10.0)
	s["wall_t"] = clampf(_f(s, "wall_t", 0.9), 0.3, 1.5)
	s["wall_h"] = clampf(_f(s, "wall_h", 2.6), 2.1, 4.5)
	s["floor_depth"] = clampf(_f(s, "floor_depth", 0.9), 0.0, 3.0)
	s["corridor_d"] = clampf(_f(s, "corridor_d", 3.0), 1.2, 8.0)
	s["glazing_deg"] = clampf(_f(s, "glazing_deg", 60.0), 35.0, 90.0)
	s["sill_h"] = clampf(_f(s, "sill_h", 0.75), 0.2, 1.5)
	s["planter_w"] = clampf(_f(s, "planter_w", 1.0), 0.0, 3.0)
	s["planter_h"] = clampf(_f(s, "planter_h", 0.55), 0.2, 1.0)
	s["roof_t"] = clampf(_f(s, "roof_t", 0.45), 0.15, 1.2)
	s["berm_run"] = clampf(_f(s, "berm_run", 1.6), 0.6, 5.0)
	s["front_cut"] = clampf(_f(s, "front_cut", 2.4), 0.5, 10.0)
	s["cisterns"] = clampi(int(_f(s, "cisterns", 2)), 0, 8)
	s["cistern_l"] = clampf(_f(s, "cistern_l", 13000.0), 500.0, 60000.0)
	if not ENTRY.has(str(s.get("entry", "left"))):
		s["entry"] = "left"
	# An older design's "inner_glazing" is the glass room front.
	if spec_in is Dictionary and not (spec_in as Dictionary).has("room_front") and bool((spec_in as Dictionary).get("inner_glazing", false)):
		s["room_front"] = "glass"
	_pick(s, "glazing_style", GLAZING_STYLES)
	_pick(s, "room_front", ROOM_FRONTS)
	_pick(s, "entry_style", ENTRY_STYLES)
	_pick(s, "bottle_pattern", BOTTLE_PATTERNS)
	_pick(s, "bottle_colors", BOTTLE_PALETTES)
	_pick(s, "end_door", END_DOORS)
	_pick(s, "plants", PLANTS)
	_pick(s, "floor", FLOORS)
	_pick(s, "ceiling", CEILINGS)
	s["inner_glazing"] = str(s["room_front"]) == "glass"
	s["viga_d"] = clampf(_f(s, "viga_d", 0.25), 0.12, 0.45)
	s["viga_spacing"] = clampf(_f(s, "viga_spacing", 0.6), 0.35, 1.5)
	s["bottle_density"] = clampf(_f(s, "bottle_density", 0.35), 0.0, 1.0)
	s["pv_panels"] = clampi(int(_f(s, "pv_panels", 6)), 0, 48)
	s["pv_tilt"] = clampf(_f(s, "pv_tilt", 45.0), 0.0, 75.0)
	s["pv_watts"] = clampf(_f(s, "pv_watts", 400.0), 50.0, 700.0)
	for b in ["vents", "bottle_ends", "skylights", "green_roof"]:
		s[b] = bool(s.get(b, false))
	s["berm_ends"] = bool(s.get("berm_ends", true))
	s["ramp"] = bool(s.get("ramp", true))
	if spec_in is Dictionary and (spec_in as Dictionary).has("room_lights"):
		s["room_lights"] = bool((spec_in as Dictionary)["room_lights"])
	if spec_in is Dictionary and (spec_in as Dictionary).get("model_lights") is Array:
		s["model_lights"] = ((spec_in as Dictionary)["model_lights"] as Array).duplicate(true)
	s["name"] = str(s.get("name", "Earthship"))
	return s


## Stable cache key (JSON keeps ints and floats apart the way a save does).
static func key_of(spec: Dictionary) -> String:
	var s := resolve(spec)
	s.erase("room_lights")
	s.erase("model_lights")
	return JSON.stringify(s)


static func to_json_safe(spec: Dictionary) -> Dictionary:
	var s := resolve(spec)
	var out := {}
	for k in s.keys():
		var v: Variant = s[k]
		if v is float and v == floorf(v) and absf(v) < 1e9 and k in ["modules", "cisterns", "pv_panels"]:
			out[k] = int(v)
		else:
			out[k] = v
	return out


static func _pick(s: Dictionary, key: String, allowed: Array) -> void:
	if not allowed.has(str(s.get(key, ""))):
		s[key] = allowed[0]
	else:
		s[key] = str(s[key])


static func color_of(spec: Dictionary, key: String, dv: Color) -> Color:
	var v: Variant = spec.get(key, null)
	if v is Color:
		return v
	if v is Array and (v as Array).size() >= 3:
		return Color(float(v[0]), float(v[1]), float(v[2]))
	return dv
