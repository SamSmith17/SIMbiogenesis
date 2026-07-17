class_name PlacedLightLayer
extends RefCounted

## Per-map placed lights.

const VERSION := 2
const MAX_LIGHTS := 200

static func create_empty() -> PlacedLightLayer:
	var layer := PlacedLightLayer.new()
	layer.lights = []
	return layer

var lights: Array = []

func save_path_for_scene(scene_key: String) -> String:
	var tag := scene_key.get_file().get_basename() if scene_key.contains("/") else scene_key
	if tag.is_empty():
		tag = "unknown_scene"
	return "user://maps/placed_lights_scene_%s.json" % tag

func save_for_scene(scene_key: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://maps"))
	var f := FileAccess.open(save_path_for_scene(scene_key), FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(serialize()))

func load_for_scene(scene_key: String) -> bool:
	var path := save_path_for_scene(scene_key)
	if not FileAccess.file_exists(path):
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		return false
	deserialize(parsed as Dictionary)
	return true

func serialize() -> Dictionary:
	return {
		"version": VERSION,
		"lights": lights,
	}

func deserialize(data: Dictionary) -> void:
	var ls: Variant = data.get("lights", [])
	if ls is Array:
		lights = ls as Array
		# Heal legacy records missing v2 fields.
		for i in lights.size():
			if not (lights[i] is Dictionary):
				continue
			var rec: Dictionary = lights[i]
			if not rec.has("shadow_enabled"):
				rec["shadow_enabled"] = true
			if not rec.has("lod_m"):
				rec["lod_m"] = 0.0

func add_light(type: String, x: float, y: float, z: float, pitch: float, yaw: float, roll: float,
		color: Color, energy: float, light_range: float, spot_angle: float,
		shadow_enabled: bool = true, lod_m: float = 0.0) -> String:
	if lights.size() >= MAX_LIGHTS:
		return ""
	var id := "light_%d_%d" % [Time.get_unix_time_from_system(), randi() % 100000]
	lights.append({
		"id": id,
		"type": type,
		"x": snappedf(x, 0.001),
		"y": snappedf(y, 0.001),
		"z": snappedf(z, 0.001),
		"pitch": snappedf(pitch, 0.001),
		"yaw": snappedf(yaw, 0.001),
		"roll": snappedf(roll, 0.001),
		"color": color.to_html(false),
		"energy": snappedf(energy, 0.01),
		"range": snappedf(light_range, 0.1),
		"spot_angle": snappedf(spot_angle, 0.1),
		"shadow_enabled": shadow_enabled,
		"lod_m": snappedf(lod_m, 1.0),
	})
	return id

func update_light(id: String, props: Dictionary) -> bool:
	for i in lights.size():
		if str(lights[i].get("id", "")) == id:
			var light: Dictionary = lights[i]
			for k in props:
				light[k] = props[k]
			lights[i] = light
			return true
	return false

func remove_light(id: String) -> bool:
	for i in lights.size():
		if str(lights[i].get("id", "")) == id:
			lights.remove_at(i)
			return true
	return false

func find_light(id: String) -> Dictionary:
	for l in lights:
		if str(l.get("id", "")) == id:
			return l
	return {}
