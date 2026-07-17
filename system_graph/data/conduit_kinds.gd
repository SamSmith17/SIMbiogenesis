class_name ConduitKinds
extends RefCounted

## Registry of physical 3D conduit styles (extension cord, hose, pipe, etc.).
## Maps graph connection polarity / resource_type to a renderable conduit profile.
## User extensions load from user://conduit_kinds.cfg (never committed).

const CONFIG_PATH := "user://conduit_kinds.cfg"

## Loss-model fields (Wave 8):
##  Electrical kinds:
##    resistance_ohm_per_m — ROUND-TRIP loop resistance per metre of run
##      (both conductors). Copper resistivity per AWG from NEC Ch.9 Table 8.
##    ampacity_a           — continuous current rating (NEC 400.5 flexible cords
##                           / NEC 310.16 building wire).
##    nominal_volts        — operating voltage used to derive current from power.
##  Fluid kinds:
##    inner_diameter_m     — hydraulic inner diameter.
##    hw_c                 — Hazen-Williams roughness coefficient C
##                           (Mays, Water Distribution Systems Handbook, ~150 smooth plastic).
##    max_flow_lpm         — practical flow rating.
##    burst_pressure_psi   — burst rating (overload/burst threshold).
##  Light kinds additionally set:
##    is_light: true, bulb_spacing_m (0 = continuous emissive strip),
##    watts_per_m, light_color.
const BUILTIN: Dictionary = {
	"extension_cord": {
		"label": "Extension Cord",
		"radius_m": 0.006,
		"color": Color(0.15, 0.15, 0.15, 1.0),
		"roughness": 0.85,
		"metallic": 0.0,
		"flexible": true,
		"sag_amount": 0.35,
		"ground_drape": true,
		# 16 AWG copper: 13.2 mOhm/m/conductor -> 26.4 mOhm/m loop (NEC Ch.9 T8).
		"resistance_ohm_per_m": 0.0264,
		"ampacity_a": 13.0,  # NEC 400.5 16 AWG cord
		"nominal_volts": 120.0,
	},
	"romex": {
		"label": "Romex / NM-B",
		"radius_m": 0.006,
		"color": Color(0.9, 0.88, 0.78, 1.0),
		"roughness": 0.8,
		"metallic": 0.0,
		"flexible": false,
		"sag_amount": 0.0,
		# 12 AWG copper: 5.21 mOhm/m/conductor -> 10.4 mOhm/m loop.
		"resistance_ohm_per_m": 0.0104,
		"ampacity_a": 20.0,  # NEC 310.16 12 AWG @60C
		"nominal_volts": 120.0,
	},
	"dc_solar": {
		"label": "DC Solar Wire",
		"radius_m": 0.005,
		"color": Color(0.08, 0.08, 0.1, 1.0),
		"roughness": 0.8,
		"metallic": 0.0,
		"flexible": true,
		"sag_amount": 0.1,
		# 10 AWG PV wire: 3.28 mOhm/m/conductor -> 6.6 mOhm/m loop.
		"resistance_ohm_per_m": 0.0066,
		"ampacity_a": 30.0,  # NEC 310.16 10 AWG
		"nominal_volts": 48.0,
	},
	"garden_hose": {
		"label": "Garden Hose",
		"radius_m": 0.012,
		"color": Color(0.18, 0.55, 0.22, 1.0),
		"roughness": 0.7,
		"metallic": 0.0,
		"flexible": true,
		"sag_amount": 0.25,
		"ground_drape": true,
		"inner_diameter_m": 0.016,  # 5/8 in ID
		"hw_c": 140.0,
		"max_flow_lpm": 40.0,
		"burst_pressure_psi": 350.0,
	},
	"pvc_pipe": {
		"label": "PVC / ABS Pipe",
		"radius_m": 0.025,
		"color": Color(0.92, 0.92, 0.95, 1.0),
		"roughness": 0.35,
		"metallic": 0.0,
		"flexible": false,
		"sag_amount": 0.0,
		"inner_diameter_m": 0.0266,  # 1 in Sch40 ID
		"hw_c": 150.0,
		"max_flow_lpm": 100.0,
		"burst_pressure_psi": 450.0,
	},
	"pex_red": {
		"label": "PEX (Red / Hot)",
		"radius_m": 0.008,
		"color": Color(0.78, 0.16, 0.14, 1.0),
		"roughness": 0.45,
		"metallic": 0.0,
		"flexible": true,
		"sag_amount": 0.08,
		"inner_diameter_m": 0.0121,  # 1/2 in PEX ID
		"hw_c": 150.0,
		"max_flow_lpm": 30.0,
		"burst_pressure_psi": 480.0,
	},
	"pex_blue": {
		"label": "PEX (Blue / Cold)",
		"radius_m": 0.008,
		"color": Color(0.16, 0.34, 0.78, 1.0),
		"roughness": 0.45,
		"metallic": 0.0,
		"flexible": true,
		"sag_amount": 0.08,
		"inner_diameter_m": 0.0121,
		"hw_c": 150.0,
		"max_flow_lpm": 30.0,
		"burst_pressure_psi": 480.0,
	},
	"pex_white": {
		"label": "PEX (White)",
		"radius_m": 0.008,
		"color": Color(0.9, 0.9, 0.88, 1.0),
		"roughness": 0.45,
		"metallic": 0.0,
		"flexible": true,
		"sag_amount": 0.08,
		"inner_diameter_m": 0.0121,
		"hw_c": 150.0,
		"max_flow_lpm": 30.0,
		"burst_pressure_psi": 480.0,
	},
	"ethernet": {
		"label": "Ethernet",
		"radius_m": 0.003,
		"color": Color(0.05, 0.05, 0.05, 1.0),
		"roughness": 0.9,
		"metallic": 0.0,
		"flexible": true,
		"sag_amount": 0.15,
		# 24 AWG copper: 84.2 mOhm/m/conductor -> 168 mOhm/m loop (PoE pair).
		"resistance_ohm_per_m": 0.168,
		"ampacity_a": 0.6,  # IEEE 802.3bt per-pair limit
		"nominal_volts": 48.0,
	},
	"ducting": {
		"label": "Ducting",
		"radius_m": 0.08,
		"color": Color(0.75, 0.78, 0.82, 1.0),
		"roughness": 0.5,
		"metallic": 0.1,
		"flexible": false,
		"sag_amount": 0.0,
		"inner_diameter_m": 0.15,
		"hw_c": 120.0,
		"max_flow_lpm": 5000.0,
		"burst_pressure_psi": 10.0,
	},
	"led_strip": {
		"label": "LED Strip",
		"radius_m": 0.004,
		"color": Color(0.85, 0.85, 0.8, 1.0),
		"roughness": 0.5,
		"metallic": 0.0,
		"flexible": true,
		"sag_amount": 0.05,
		"is_light": true,
		"bulb_spacing_m": 0.0,  # continuous emissive strip, no discrete bulbs
		"watts_per_m": 14.0,    # 5050 SMD strip @ 12 V
		"light_color": Color(1.0, 0.92, 0.8, 1.0),
		# 12 V strip copper traces: ~0.15 Ohm/m loop (typical 10 mm 2 oz PCB).
		"resistance_ohm_per_m": 0.15,
		"ampacity_a": 5.0,
		"nominal_volts": 12.0,
	},
	"led_fairy": {
		"label": "Fairy Lights",
		"radius_m": 0.0015,
		"color": Color(0.35, 0.3, 0.2, 1.0),
		"roughness": 0.9,
		"metallic": 0.0,
		"flexible": true,
		"sag_amount": 0.3,
		"ground_drape": true,
		"is_light": true,
		"bulb_spacing_m": 0.15,
		"watts_per_m": 0.6,  # 5 V USB micro-LED string
		"light_color": Color(1.0, 0.88, 0.65, 1.0),
		# 30 AWG copper: 0.34 Ohm/m/conductor -> 0.68 Ohm/m loop.
		"resistance_ohm_per_m": 0.68,
		"ampacity_a": 0.8,
		"nominal_volts": 5.0,
	},
	"led_patio": {
		"label": "Patio String Lights",
		"radius_m": 0.004,
		"color": Color(0.08, 0.08, 0.08, 1.0),
		"roughness": 0.85,
		"metallic": 0.0,
		"flexible": true,
		"sag_amount": 0.35,
		"is_light": true,
		"bulb_spacing_m": 0.9,
		"watts_per_m": 3.3,  # ~3 W LED filament bulb every 0.9 m
		"light_color": Color(1.0, 0.82, 0.55, 1.0),
		# 18 AWG SPT-1 lamp cord: 21 mOhm/m/conductor -> 42 mOhm/m loop.
		"resistance_ohm_per_m": 0.042,
		"ampacity_a": 10.0,
		"nominal_volts": 120.0,
	},
}

## Default mapping from ResourceKinds id → conduit type id.
const RESOURCE_DEFAULTS: Dictionary = {
	"electric": "extension_cord",
	"water": "garden_hose",
	"hot_water": "pex_red",
	"woodgas": "pvc_pipe",
	"thermal": "ducting",
	"biomass": "pvc_pipe",
	"plastic_waste": "pvc_pipe",
	"plastic_shred": "pvc_pipe",
	"biochar": "pvc_pipe",
	"food": "garden_hose",
	"propane": "pvc_pipe",
	"money": "pvc_pipe",
	"chore_hours": "pvc_pipe",
}

static var _extra: Dictionary = {}
static var _loaded: bool = false


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	_extra.clear()
	if not FileAccess.file_exists(CONFIG_PATH):
		return
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		return
	for section in cfg.get_sections():
		if section == "meta":
			continue
		var label: String = str(cfg.get_value(section, "label", section.capitalize()))
		var radius: float = float(cfg.get_value(section, "radius_m", 0.01))
		var cr: float = float(cfg.get_value(section, "color_r", 0.58))
		var cg: float = float(cfg.get_value(section, "color_g", 0.64))
		var cb: float = float(cfg.get_value(section, "color_b", 0.72))
		var rough: float = float(cfg.get_value(section, "roughness", 0.7))
		var metal: float = float(cfg.get_value(section, "metallic", 0.0))
		var flex: bool = bool(cfg.get_value(section, "flexible", true))
		var sag: float = float(cfg.get_value(section, "sag_amount", 0.3))
		_extra[section] = {
			"label": label,
			"radius_m": radius,
			"color": Color(cr, cg, cb, 1.0),
			"roughness": rough,
			"metallic": metal,
			"flexible": flex,
			"sag_amount": sag,
		}


static func all_types() -> Array:
	_ensure_loaded()
	var keys: Array = BUILTIN.keys()
	for k: String in _extra.keys():
		if not keys.has(k):
			keys.append(k)
	keys.sort()
	return keys


static func has_type(type_id: String) -> bool:
	_ensure_loaded()
	return BUILTIN.has(type_id) or _extra.has(type_id)


static func type_meta(type_id: String) -> Dictionary:
	_ensure_loaded()
	if BUILTIN.has(type_id):
		return (BUILTIN[type_id] as Dictionary).duplicate(true)
	if _extra.has(type_id):
		return (_extra[type_id] as Dictionary).duplicate(true)
	return (BUILTIN["garden_hose"] as Dictionary).duplicate(true)


static func display_name(type_id: String) -> String:
	return str(type_meta(type_id).get("label", type_id.capitalize()))


## True when the conduit kind carries electrical power (has a loop resistance).
static func is_electrical_type(type_id: String) -> bool:
	return type_meta(type_id).has("resistance_ohm_per_m")


## True when the conduit kind carries fluid (has a hydraulic inner diameter).
static func is_fluid_type(type_id: String) -> bool:
	return type_meta(type_id).has("inner_diameter_m")


## True when the conduit kind is itself a light source (LED strip/fairy/patio).
static func is_light_type(type_id: String) -> bool:
	return bool(type_meta(type_id).get("is_light", false))


## True when flexible slack should drape onto the ground instead of hanging.
static func is_ground_drape_type(type_id: String) -> bool:
	return bool(type_meta(type_id).get("ground_drape", false))


## Derive conduit type from a graph connection dict (respects conduit_type override).
static func derive_type_for_connection(conn: Dictionary) -> String:
	var override: String = str(conn.get("conduit_type", ""))
	if not override.is_empty() and has_type(override):
		return override
	var pol: String = str(conn.get("polarity", ""))
	if pol in ["ac", "load", "positive", "negative", "smart_battery"]:
		return "extension_cord"
	var rtype: String = str(conn.get("resource_type", ""))
	if not rtype.is_empty() and RESOURCE_DEFAULTS.has(rtype):
		return str(RESOURCE_DEFAULTS[rtype])
	if not rtype.is_empty():
		return "garden_hose"
	return "extension_cord"


static func make_material(type_id: String) -> StandardMaterial3D:
	var meta: Dictionary = type_meta(type_id)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = meta.get("color", Color.WHITE) as Color
	mat.roughness = float(meta.get("roughness", 0.7))
	mat.metallic = float(meta.get("metallic", 0.0))
	return mat


## Sum Euclidean length of a polyline (control points or sampled path).
static func polyline_length_m(points: PackedVector3Array) -> float:
	var total := 0.0
	for i: int in range(1, points.size()):
		total += points[i].distance_to(points[i - 1])
	return total


## Parse route_3d waypoint dicts into world positions.
static func waypoints_to_vectors(route_3d: Array) -> Array:
	var out: Array = []
	for wp: Variant in route_3d:
		if wp is Vector3:
			out.append(wp)
		elif wp is Dictionary:
			out.append(Vector3(
				float(wp.get("x", 0.0)),
				float(wp.get("y", 0.0)),
				float(wp.get("z", 0.0)),
			))
	return out


## Serialize a world position (+ optional pin path) for GraphModel storage.
static func waypoint_dict(pos: Vector3, pin_path: String = "") -> Dictionary:
	var d: Dictionary = {"x": pos.x, "y": pos.y, "z": pos.z}
	if not pin_path.is_empty():
		d["pin_path"] = pin_path
	return d


## Ensure v4 conduit fields exist on a connection dict (in-place migration).
static func migrate_connection_conduit_fields(conn: Dictionary) -> void:
	if not conn.has("route_3d"):
		conn["route_3d"] = []
	if not conn.has("conduit_type"):
		conn["conduit_type"] = ""
	if not conn.has("route_length_m"):
		conn["route_length_m"] = 0.0
