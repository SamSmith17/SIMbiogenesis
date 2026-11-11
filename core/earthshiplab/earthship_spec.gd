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
	s["inner_glazing"] = bool(s.get("inner_glazing", false))
	s["berm_ends"] = bool(s.get("berm_ends", true))
	s["ramp"] = bool(s.get("ramp", true))
	s["name"] = str(s.get("name", "Earthship"))
	return s


## Stable cache key (JSON keeps ints and floats apart the way a save does).
static func key_of(spec: Dictionary) -> String:
	return JSON.stringify(resolve(spec))


static func to_json_safe(spec: Dictionary) -> Dictionary:
	var s := resolve(spec)
	var out := {}
	for k in s.keys():
		var v: Variant = s[k]
		if v is float and v == floorf(v) and absf(v) < 1e9 and k in ["modules", "cisterns"]:
			out[k] = int(v)
		else:
			out[k] = v
	return out


static func color_of(spec: Dictionary, key: String, dv: Color) -> Color:
	var v: Variant = spec.get(key, null)
	if v is Color:
		return v
	if v is Array and (v as Array).size() >= 3:
		return Color(float(v[0]), float(v[1]), float(v[2]))
	return dv
