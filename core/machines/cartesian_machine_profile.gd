class_name CartesianMachineProfile
extends RefCounted

## Generalized 3-axis (X/Y/Z) kinematic binding for ANY Cartesian machine model
## (CNC router, mill, laser, FDM/flake 3D printer, earth printer …). One
## kinematics engine (gameplay/cnc_machine_runtime.gd) animates every machine by
## reading this profile, so a user can import a new GLB and simply TAG which
## sub-node is each axis + which local direction it travels — no per-model code.
##
## Per axis we store:
##   node         GLB sub-node name (find_child target) that physically moves
##   axis         unit travel direction in that node's PARENT-local frame
##   min_local    displacement from the GLB rest pose at path-norm 0
##   max_local    displacement from the GLB rest pose at path-norm 1
##   home_local   displacement from rest for park / home (origin)
##   travel_local legacy (= max − min); still written for older readers
##   invert       flip the sign (e.g. a bed that drops as Z increases)
##
## Animation lerps min→max by normalized toolpath progress (0..1). Machine Setup
## exposes min/max/home as live jog-calibrated values so the player never has to
## guess the GLB's internal unit scale. Graph work_*_mm is separate (sim volume).

const STORE_PATH := "user://machines/profiles.json"
const AXIS_KEYS := ["x", "y", "z"]

var model_id: String = ""
## axis key -> {node, axis, min_local, max_local, home_local, travel_local, invert}
var axes: Dictionary = {}
var tool_node: String = ""


## Baked defaults for the shipped machines (verified sub-node names from the GLB
## node dumps). min/max start at 0 so Machine Setup / AABB fallback fills them;
## the jog UI lets the player calibrate real soft limits by eye.
const BUILTIN: Dictionary = {
	"cnc_router": {
		"tool_node": "PorterCableRouter",
		"axes": {
			"x": {"node": "X Axis", "axis": [1.0, 0.0, 0.0],
				"min_local": 0.0, "max_local": 0.0, "home_local": 0.0, "invert": false},
			"y": {"node": "Y axis", "axis": [0.0, 0.0, 1.0],
				"min_local": 0.0, "max_local": 0.0, "home_local": 0.0, "invert": false},
			"z": {"node": "Z Axis", "axis": [0.0, 1.0, 0.0],
				"min_local": 0.0, "max_local": 0.0, "home_local": 0.0, "invert": false},
		},
	},
	"trash_printer": {
		"tool_node": "3/4\" NPT PVC Extruder Assembly 5/8\" Auger",
		"axes": {
			# Y Axis (gantry) carries X Assembly (toolhead); the bed moves in Z
			# (drops as the print grows -> inverted).
			"x": {"node": "X Assembly", "axis": [1.0, 0.0, 0.0],
				"min_local": 0.0, "max_local": 0.0, "home_local": 0.0, "invert": false},
			"y": {"node": "Y Axis", "axis": [0.0, 0.0, 1.0],
				"min_local": 0.0, "max_local": 0.0, "home_local": 0.0, "invert": false},
			"z": {"node": "Z bed", "axis": [0.0, 1.0, 0.0],
				"min_local": 0.0, "max_local": 0.0, "home_local": 0.0, "invert": true},
		},
	},
	"mud_printer": {
		"tool_node": "Fog Nozzle",
		"axes": {
			"x": {"node": "X assembly", "axis": [1.0, 0.0, 0.0],
				"min_local": 0.0, "max_local": 0.0, "home_local": 0.0, "invert": false},
			"y": {"node": "X Y Assembly", "axis": [0.0, 0.0, 1.0],
				"min_local": 0.0, "max_local": 0.0, "home_local": 0.0, "invert": false},
			"z": {"node": "Z assembly", "axis": [0.0, 1.0, 0.0],
				"min_local": 0.0, "max_local": 0.0, "home_local": 0.0, "invert": false},
		},
	},
}


static func default_for(mid: String) -> CartesianMachineProfile:
	var p := CartesianMachineProfile.new()
	p.model_id = mid
	var raw: Variant = BUILTIN.get(mid, {})
	if raw is Dictionary:
		p._apply_raw(raw as Dictionary)
	if p.axes.is_empty():
		# Unknown model: seed empty axis rows so the setup UI has slots to fill.
		for k: String in AXIS_KEYS:
			p.axes[k] = _blank_axis(k)
	return p


## Returns the saved profile for a model if present, otherwise the baked default.
static func get_profile(mid: String) -> CartesianMachineProfile:
	var store := _load_store()
	if store.has(mid) and store[mid] is Dictionary:
		var p := CartesianMachineProfile.new()
		p.model_id = mid
		p._apply_raw(store[mid] as Dictionary)
		if not p.axes.is_empty():
			return p
	return default_for(mid)


static func save_profile(profile: CartesianMachineProfile) -> void:
	if profile == null or profile.model_id.is_empty():
		return
	var store := _load_store()
	store[profile.model_id] = profile.to_dict()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://machines"))
	var f := FileAccess.open(STORE_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(store))


static func has_saved(mid: String) -> bool:
	return _load_store().has(mid)


func axis_node(key: String) -> String:
	var a: Variant = axes.get(key, {})
	return str((a as Dictionary).get("node", "")) if a is Dictionary else ""


func axis_dir(key: String) -> Vector3:
	var a: Variant = axes.get(key, {})
	if a is Dictionary:
		var v := _to_vec3((a as Dictionary).get("axis", null), _default_axis_vec(key))
		var s := -1.0 if bool((a as Dictionary).get("invert", false)) else 1.0
		return (v.normalized() if v.length_squared() > 1e-9 else _default_axis_vec(key)) * s
	return _default_axis_vec(key)


func axis_travel_local(key: String) -> float:
	return axis_max_local(key) - axis_min_local(key)


func axis_min_local(key: String) -> float:
	var a: Variant = axes.get(key, {})
	if not (a is Dictionary):
		return 0.0
	var ad := a as Dictionary
	if ad.has("min_local"):
		return float(ad.get("min_local", 0.0))
	# Legacy: travel_local alone meant min=0, max=travel.
	return 0.0


func axis_max_local(key: String) -> float:
	var a: Variant = axes.get(key, {})
	if not (a is Dictionary):
		return 0.0
	var ad := a as Dictionary
	if ad.has("max_local"):
		return float(ad.get("max_local", 0.0))
	return float(ad.get("travel_local", 0.0))


func axis_home_local(key: String) -> float:
	var a: Variant = axes.get(key, {})
	if not (a is Dictionary):
		return 0.0
	var ad := a as Dictionary
	if ad.has("home_local"):
		return float(ad.get("home_local", 0.0))
	return axis_min_local(key)


func set_axis(key: String, node: String, dir: Vector3, travel_local: float, invert: bool) -> void:
	## Legacy helper — travel maps to min=0, max=travel, home=0.
	set_axis_limits(key, node, dir, 0.0, travel_local, 0.0, invert)


func set_axis_limits(key: String, node: String, dir: Vector3,
		min_local: float, max_local: float, home_local: float, invert: bool) -> void:
	var lo := minf(min_local, max_local)
	var hi := maxf(min_local, max_local)
	axes[key] = {
		"node": node,
		"axis": [dir.x, dir.y, dir.z],
		"min_local": lo,
		"max_local": hi,
		"home_local": clampf(home_local, lo, hi) if hi > lo else home_local,
		"travel_local": hi - lo,
		"invert": invert,
	}


func is_configured() -> bool:
	for k: String in AXIS_KEYS:
		if axis_node(k).is_empty():
			return false
	return true


func to_dict() -> Dictionary:
	var out_axes: Dictionary = {}
	for k: String in AXIS_KEYS:
		var a: Variant = axes.get(k, {})
		if not (a is Dictionary):
			continue
		var ad := a as Dictionary
		var v := _to_vec3(ad.get("axis", null), _default_axis_vec(k))
		var lo := float(ad.get("min_local", 0.0))
		var hi := float(ad.get("max_local", ad.get("travel_local", 0.0)))
		var home := float(ad.get("home_local", lo))
		out_axes[k] = {
			"node": str(ad.get("node", "")),
			"axis": [v.x, v.y, v.z],
			"min_local": lo,
			"max_local": hi,
			"home_local": home,
			"travel_local": hi - lo,
			"invert": bool(ad.get("invert", false)),
		}
	return {"model_id": model_id, "tool_node": tool_node, "axes": out_axes}


func _apply_raw(raw: Dictionary) -> void:
	if raw.has("tool_node"):
		tool_node = str(raw.get("tool_node", ""))
	if raw.has("model_id"):
		model_id = str(raw.get("model_id", model_id))
	axes = {}
	var raw_axes: Variant = raw.get("axes", {})
	if raw_axes is Dictionary:
		for k: String in AXIS_KEYS:
			var a: Variant = (raw_axes as Dictionary).get(k, null)
			if a is Dictionary:
				var ad := a as Dictionary
				var travel := float(ad.get("travel_local", 0.0))
				var lo := float(ad.get("min_local", 0.0))
				var hi := float(ad.get("max_local", travel if travel > 0.0 else 0.0))
				if not ad.has("max_local") and not ad.has("min_local") and travel > 0.0:
					lo = 0.0
					hi = travel
				var home := float(ad.get("home_local", lo))
				axes[k] = {
					"node": str(ad.get("node", "")),
					"axis": _to_vec3(ad.get("axis", null), _default_axis_vec(k)),
					"min_local": lo,
					"max_local": hi,
					"home_local": home,
					"travel_local": hi - lo,
					"invert": bool(ad.get("invert", false)),
				}


static func _blank_axis(key: String) -> Dictionary:
	return {
		"node": "", "axis": _default_axis_vec(key),
		"min_local": 0.0, "max_local": 0.0, "home_local": 0.0,
		"travel_local": 0.0, "invert": false,
	}


## Heuristic auto-tag: scan the instanced model for Node3D descendants whose name
## contains "x"/"y"/"z axis" (or "assembly"/"bed"/"gantry") to pre-fill the setup
## UI. Returns {axis_key: node_name} suggestions.
static func auto_detect_axes(model_root: Node3D) -> Dictionary:
	var out: Dictionary = {}
	if model_root == null:
		return out
	var nodes := model_root.find_children("*", "Node3D", true, false)
	for key: String in AXIS_KEYS:
		var best := ""
		var best_score := 0
		for n in nodes:
			var nm := str((n as Node).name).to_lower()
			var score := 0
			if nm.contains(key + " axis") or nm.contains(key + " assembly"):
				score = 3
			elif nm.begins_with(key + " ") or nm == key:
				score = 2
			elif key == "z" and nm.contains("bed"):
				score = 2
			if score > best_score:
				best_score = score
				best = str((n as Node).name)
		if not best.is_empty():
			out[key] = best
	return out


static func _load_store() -> Dictionary:
	if not FileAccess.file_exists(STORE_PATH):
		return {}
	var f := FileAccess.open(STORE_PATH, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return (parsed as Dictionary) if parsed is Dictionary else {}


static func _default_axis_vec(key: String) -> Vector3:
	match key:
		"x": return Vector3(1.0, 0.0, 0.0)
		"y": return Vector3(0.0, 0.0, 1.0)
		"z": return Vector3(0.0, 1.0, 0.0)
		_: return Vector3(1.0, 0.0, 0.0)


static func _to_vec3(v: Variant, fallback: Vector3) -> Vector3:
	if v is Vector3:
		return v
	if v is Array and (v as Array).size() >= 3:
		var a: Array = v
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return fallback
