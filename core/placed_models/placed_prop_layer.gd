class_name PlacedPropLayer
extends RefCounted

## Per-map placed GLB props + OSM building replacements.

const VERSION := 1
const MAX_PROPS := 500


static func create_empty() -> PlacedPropLayer:
	var layer := PlacedPropLayer.new()
	layer.props = []
	return layer


var props: Array = []


func save_path_for_scene(scene_key: String) -> String:
	var tag := scene_key.get_file().get_basename() if scene_key.contains("/") else scene_key
	if tag.is_empty():
		tag = "unknown_scene"
	return "user://maps/placed_props_scene_%s.json" % tag


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


func save_path_for_map(lat: float, lon: float) -> String:
	return "user://maps/placed_props_%s_%s.json" % [CoordToken.token(lat), CoordToken.token(lon)]


func save(lat: float, lon: float) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://maps"))
	var f := FileAccess.open(save_path_for_map(lat, lon), FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(serialize()))


func load_for_map(lat: float, lon: float) -> bool:
	var path := save_path_for_map(lat, lon)
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
	return {"version": VERSION, "props": props.duplicate(true)}


func deserialize(data: Dictionary) -> void:
	props = []
	for item in data.get("props", []):
		if item is Dictionary:
			props.append(item)


func find_by_id(prop_id: String) -> Dictionary:
	for item in props:
		if item is Dictionary and str(item.get("id", "")) == prop_id:
			return item
	return {}


func add_free_prop(model_id: String, x: float, y_offset: float, z: float,
		yaw: float = 0.0, pitch: float = 0.0, roll: float = 0.0,
		scale: float = 1.0, ground_y: float = NAN) -> String:
	if props.size() >= MAX_PROPS:
		return ""
	var rec := _new_record(model_id, x, y_offset, z, yaw, pitch, roll, scale, ground_y)
	rec["type"] = "free"
	props.append(rec)
	return str(rec["id"])


func add_osm_prop(building_idx: int, model_id: String, x: float, y_offset: float, z: float,
		yaw: float = 0.0, pitch: float = 0.0, roll: float = 0.0,
		scale: float = 1.0, ground_y: float = NAN) -> String:
	remove_osm_for_building(building_idx)
	if props.size() >= MAX_PROPS:
		return ""
	var rec := _new_record(model_id, x, y_offset, z, yaw, pitch, roll, scale, ground_y)
	rec["type"] = "osm"
	rec["building_idx"] = building_idx
	props.append(rec)
	return str(rec["id"])


func update_prop(prop_id: String, patch: Dictionary) -> bool:
	for i in props.size():
		var d: Dictionary = props[i]
		if str(d.get("id", "")) != prop_id:
			continue
		for k in patch.keys():
			d[k] = patch[k]
		props[i] = d
		return true
	return false


func remove_prop(prop_id: String) -> bool:
	for i in props.size():
		if str((props[i] as Dictionary).get("id", "")) == prop_id:
			props.remove_at(i)
			return true
	return false


func remove_nearest(world_xz: Vector2, radius_m: float = 3.0) -> bool:
	var best_i := -1
	var best_d := radius_m * radius_m
	for i in props.size():
		var d: Dictionary = props[i]
		var pt := Vector2(float(d.get("x", 0.0)), float(d.get("z", 0.0)))
		var dist := pt.distance_squared_to(world_xz)
		if dist < best_d:
			best_d = dist
			best_i = i
	if best_i < 0:
		return false
	props.remove_at(best_i)
	return true


func remove_osm_for_building(building_idx: int) -> void:
	var kept: Array = []
	for item in props:
		if not (item is Dictionary):
			continue
		var d: Dictionary = item
		if str(d.get("type", "")) == "osm" and int(d.get("building_idx", -1)) == building_idx:
			continue
		kept.append(d)
	props = kept


func get_replaced_building_indices() -> Array[int]:
	var out: Array[int] = []
	for item in props:
		if not (item is Dictionary):
			continue
		var d: Dictionary = item
		if str(d.get("type", "")) == "osm":
			out.append(int(d.get("building_idx", -1)))
	return out


func is_building_replaced(building_idx: int) -> bool:
	for item in props:
		if not (item is Dictionary):
			continue
		var d: Dictionary = item
		if str(d.get("type", "")) == "osm" and int(d.get("building_idx", -1)) == building_idx:
			return true
	return false


static func _new_record(model_id: String, x: float, y_offset: float, z: float,
		yaw: float, pitch: float, roll: float, scale: float,
		ground_y: float) -> Dictionary:
	var rec := {
		"id": _new_id(),
		"model_id": model_id,
		"x": x, "z": z,
		"yaw": yaw, "pitch": pitch, "roll": roll,
		"scale": scale,
	}
	if not is_nan(y_offset):
		rec["y_offset"] = y_offset
	if not is_nan(ground_y):
		rec["ground_y"] = ground_y
	return rec


static func _new_id() -> String:
	return "prop_%d_%d" % [Time.get_unix_time_from_system(), randi() % 1000000]
