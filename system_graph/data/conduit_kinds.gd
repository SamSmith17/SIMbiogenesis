class_name ConduitKinds
extends RefCounted

## Registry of physical 3D conduit styles (extension cord, hose, pipe, etc.).
## Maps graph connection polarity / resource_type to a renderable conduit profile.
## User extensions load from user://conduit_kinds.cfg (never committed).

const CONFIG_PATH := "user://conduit_kinds.cfg"

const BUILTIN: Dictionary = {
	"extension_cord": {
		"label": "Extension Cord",
		"radius_m": 0.006,
		"color": Color(0.15, 0.15, 0.15, 1.0),
		"roughness": 0.85,
		"metallic": 0.0,
		"flexible": true,
		"sag_amount": 0.35,
	},
	"garden_hose": {
		"label": "Garden Hose",
		"radius_m": 0.012,
		"color": Color(0.18, 0.55, 0.22, 1.0),
		"roughness": 0.7,
		"metallic": 0.0,
		"flexible": true,
		"sag_amount": 0.25,
	},
	"pvc_pipe": {
		"label": "PVC / ABS Pipe",
		"radius_m": 0.025,
		"color": Color(0.92, 0.92, 0.95, 1.0),
		"roughness": 0.35,
		"metallic": 0.0,
		"flexible": false,
		"sag_amount": 0.0,
	},
	"ethernet": {
		"label": "Ethernet",
		"radius_m": 0.003,
		"color": Color(0.05, 0.05, 0.05, 1.0),
		"roughness": 0.9,
		"metallic": 0.0,
		"flexible": true,
		"sag_amount": 0.15,
	},
	"ducting": {
		"label": "Ducting",
		"radius_m": 0.08,
		"color": Color(0.75, 0.78, 0.82, 1.0),
		"roughness": 0.5,
		"metallic": 0.1,
		"flexible": false,
		"sag_amount": 0.0,
	},
}

## Default mapping from ResourceKinds id → conduit type id.
const RESOURCE_DEFAULTS: Dictionary = {
	"electric": "extension_cord",
	"water": "garden_hose",
	"hot_water": "garden_hose",
	"woodgas": "pvc_pipe",
	"thermal": "ducting",
	"biomass": "pvc_pipe",
	"plastic_waste": "pvc_pipe",
	"plastic_shred": "pvc_pipe",
	"biochar": "pvc_pipe",
	"food": "garden_hose",
	"propane": "pvc_pipe",
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
