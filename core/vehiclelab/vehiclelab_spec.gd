class_name VehicleSpec
extends RefCounted

## A living vehicle as data: the record key `vehicle_spec` on a placed prop,
## the designer's document and the library entry. Pure — no nodes.
##
##   type         one of VehicleCatalog.TYPE_ORDER
##   chassis_id   a VehicleCatalog.CHASSIS key; `chassis` = overrides of it
##   body_id      a VehicleCatalog.BODIES key;  `body`    = overrides of it
##   paint        body / roof / stripe / trim / wheels colours ([r, g, b]),
##                stripe_on
##   interior     {elements: [...]} — see VehicleDesign.interior_elements:
##                {id, type, x (across, + = the curb / right side), z (along
##                the living box from its FRONT; < 0 counts from the rear),
##                w, l, h (top above the floor), yaw (0 = long axis along
##                the vehicle, 90 = across)}
##   exterior     {elements: [...]} (the designer's roof / side items)
##   trip         {one_way_mi, fuel_price_per_gal, kwh_price}
##   seats        travelling seats incl. the driver (-1 = by type)
##   part_overrides {part id: {hidden, color}}
##
## `resolve` fills every default and adds two derived keys, `ch` (the chassis
## preset with the overrides applied) and `bd` (the body likewise), which
## `to_json_safe` strips again.

const VERSION := 1

const PAINT_DEFAULTS := {
	"roof": [0.93, 0.93, 0.92], "stripe": [0.12, 0.32, 0.55], "trim": [0.12, 0.12, 0.13],
	"wheels": [0.72, 0.73, 0.75], "stripe_on": false,
}

const CHASSIS_KEYS := ["wheelbase_m", "track_m", "front_overhang_m", "tyre_d_m", "tyre_w_m",
	"dually", "rear_axles", "frame_h_m", "hood_len_m", "cab_len_m", "cab_h_m", "cab_w_m",
	"rear_overhang_m", "curb_kg", "gvwr_kg", "fuel", "tank_l", "battery_kwh", "max_steer_deg", "top_speed_mps"]
const BODY_KEYS := ["length_m", "width_m", "height_m", "floor_h_m", "roof", "cd",
	"wall_kg_m2", "windows", "rear_door", "side_door", "corner_r_m"]


static func default_spec(type: String = "van") -> Dictionary:
	var ti := VehicleCatalog.type_info(type)
	return {
		"version": VERSION, "name": str(ti.get("label", "Vehicle")), "type": type,
		"chassis_id": str(ti.get("chassis", "")), "body_id": str(ti.get("body", "")),
		"chassis": {}, "body": {}, "paint": {},
		"interior": {"elements": []}, "exterior": {"elements": []},
		"trip": {"one_way_mi": 0.0, "fuel_price_per_gal": 4.5, "kwh_price": 0.35},
		"seats": -1, "part_overrides": {},
	}


static func resolve(spec: Dictionary) -> Dictionary:
	var s: Dictionary = spec.duplicate(true)
	var type := str(s.get("type", "van"))
	if not VehicleCatalog.TYPES.has(type):
		type = "van"
	s["type"] = type
	var base := default_spec(type)
	for k in base:
		if not s.has(k):
			s[k] = base[k]
	if not VehicleCatalog.CHASSIS.has(str(s["chassis_id"])):
		s["chassis_id"] = base["chassis_id"]
	if not VehicleCatalog.BODIES.has(str(s["body_id"])):
		s["body_id"] = base["body_id"]
	var ch: Dictionary = VehicleCatalog.chassis(str(s["chassis_id"])).duplicate(true)
	var cho: Dictionary = s.get("chassis", {}) if s.get("chassis", {}) is Dictionary else {}
	for k in CHASSIS_KEYS:
		if cho.has(k):
			ch[k] = cho[k]
	var bd: Dictionary = VehicleCatalog.body(str(s["body_id"])).duplicate(true)
	var bdo: Dictionary = s.get("body", {}) if s.get("body", {}) is Dictionary else {}
	for k in BODY_KEYS:
		if bdo.has(k):
			bd[k] = bdo[k]
	# A full-van shell is as long as the van: its preset length is 0, so the
	# shell takes the van's own (wheelbase + overhangs).
	if str(ch.get("cab", "")) == "full_van" and float(bd.get("length_m", 0.0)) <= 0.0:
		bd["length_m"] = float(ch["front_overhang_m"]) + float(ch["wheelbase_m"]) \
			+ float(ch.get("rear_overhang_m", float(ch["wheelbase_m"]) * 0.45))
	_clamp_body(bd, ch)
	s["ch"] = ch
	s["bd"] = bd
	var paint: Dictionary = s.get("paint", {}) if s.get("paint", {}) is Dictionary else {}
	var p := {}
	p["body"] = _color_arr(paint.get("body", bd.get("color", [0.95, 0.95, 0.95])))
	for k in PAINT_DEFAULTS:
		if k == "stripe_on":
			p[k] = bool(paint.get(k, PAINT_DEFAULTS[k]))
		else:
			p[k] = _color_arr(paint.get(k, PAINT_DEFAULTS[k]))
	if not paint.has("roof"):
		p["roof"] = p["body"]
	s["paint"] = p
	if not (s.get("interior", {}) is Dictionary):
		s["interior"] = {"elements": []}
	if not ((s["interior"] as Dictionary).get("elements", []) is Array):
		(s["interior"] as Dictionary)["elements"] = []
	if not (s.get("exterior", {}) is Dictionary):
		s["exterior"] = {"elements": []}
	if not (s.get("part_overrides", {}) is Dictionary):
		s["part_overrides"] = {}
	var trip: Dictionary = s.get("trip", {}) if s.get("trip", {}) is Dictionary else {}
	s["trip"] = {
		"one_way_mi": maxf(float(trip.get("one_way_mi", 0.0)), 0.0),
		"fuel_price_per_gal": maxf(float(trip.get("fuel_price_per_gal", 4.5)), 0.0),
		"kwh_price": maxf(float(trip.get("kwh_price", 0.35)), 0.0),
	}
	s["seats"] = int(s.get("seats", -1))
	return s


static func _clamp_body(bd: Dictionary, ch: Dictionary) -> void:
	bd["length_m"] = clampf(float(bd.get("length_m", 4.0)), 1.5, 14.0)
	bd["width_m"] = clampf(float(bd.get("width_m", 2.3)), 1.4, 2.6)
	var floor_min := float(ch.get("frame_h_m", 0.5)) * 0.6
	bd["floor_h_m"] = clampf(float(bd.get("floor_h_m", 0.8)), minf(floor_min, 0.15), 1.4)
	bd["height_m"] = clampf(float(bd.get("height_m", 3.0)),
		float(bd["floor_h_m"]) + 1.4, 4.2)
	bd["corner_r_m"] = clampf(float(bd.get("corner_r_m", 0.1)), 0.0, 0.4)
	bd["cd"] = clampf(float(bd.get("cd", 0.6)), 0.25, 1.0)


static func _color_arr(v: Variant) -> Array:
	if v is Color:
		var c := v as Color
		return [c.r, c.g, c.b]
	if v is Array and (v as Array).size() >= 3:
		var a := v as Array
		return [clampf(float(a[0]), 0.0, 1.0), clampf(float(a[1]), 0.0, 1.0),
			clampf(float(a[2]), 0.0, 1.0)]
	return [0.9, 0.9, 0.9]


static func color(arr: Variant) -> Color:
	var a := _color_arr(arr)
	return Color(float(a[0]), float(a[1]), float(a[2]))


## The stored form: the derived `ch` / `bd` stripped, everything JSON-able.
static func to_json_safe(spec: Dictionary) -> Dictionary:
	var s: Dictionary = spec.duplicate(true)
	s.erase("ch")
	s.erase("bd")
	return s


## A stable cache key. JSON.stringify, not var_to_str: a saved spec comes back
## with floats re-printed (609.5999999 vs 609.6), and var_to_str kept the two
## apart — the WindLab lesson.
static func key_of(spec: Dictionary) -> String:
	return str(hash(JSON.stringify(_rounded(to_json_safe(spec)), "", true)))


static func _rounded(v: Variant) -> Variant:
	# JSON hands every number back as a float: 1 and 1.0 must key alike.
	if v is float or v is int:
		var f := snappedf(float(v), 0.0001)
		return int(f) if is_equal_approx(f, roundf(f)) and absf(f) < 1.0e9 else f
	if v is Dictionary:
		var out := {}
		for k in v:
			out[str(k)] = _rounded(v[k])
		return out
	if v is Array:
		var a: Array = []
		for x in v:
			a.append(_rounded(x))
		return a
	return v


## One line for a list row: "Shuttle bus — Ford E-450 … + fiberglass shuttle".
static func describe(spec: Dictionary) -> String:
	var s := resolve(spec)
	return "%s — %s + %s" % [str(s.get("name", "")), str((s["ch"] as Dictionary).get("label", "")),
		str((s["bd"] as Dictionary).get("label", ""))]
