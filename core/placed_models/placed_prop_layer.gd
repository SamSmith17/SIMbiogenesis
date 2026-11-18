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
	return WorldPaths.scene_file("placed_props", scene_key)


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
	return WorldPaths.site_file("placed_props", lat, lon)


## False when the file could not be opened for writing.
func save(lat: float, lon: float) -> bool:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://maps"))
	var f := FileAccess.open(save_path_for_map(lat, lon), FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(serialize()))
	return true


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


## id -> record, rebuilt when `props` is replaced or changes size (a few
## callers outside this class append to or reassign `props` directly), and
## dropped by every mutator here. Cargo followers ask for each crate every
## frame: a linear scan of 500 records each was the cost.
var _index: Dictionary = {}
var _index_of: Array = []
var _index_n := -1


func _ensure_index() -> void:
	if is_same(_index_of, props) and _index_n == props.size():
		return
	_index = {}
	for item in props:
		if item is Dictionary:
			_index[str((item as Dictionary).get("id", ""))] = item
	_index_of = props
	_index_n = props.size()


func _drop_index() -> void:
	_index_n = -1


func find_by_id(prop_id: String) -> Dictionary:
	_ensure_index()
	var rec: Variant = _index.get(prop_id)
	if rec is Dictionary and str((rec as Dictionary).get("id", "")) == prop_id:
		return rec
	# A stale index (a record swapped in place by an outside writer): scan.
	for item in props:
		if item is Dictionary and str(item.get("id", "")) == prop_id:
			_drop_index()
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


## Shallow key merge, with one addition: a patch value of `null` ERASES the
## key rather than storing a null.
##
## Callers use null to mean "this no longer applies" — `stowed_in` when a crate
## is hauled out of its container, `build_state` when a structure finishes
## building. Storing the null instead would leave the key present, and every
## reader does `str(rec.get(key, ""))` or `rec.get(key) is Dictionary`; the
## first yields "<null>" (which is not empty, so the flag reads as still set)
## and the second silently works by accident. Erasing makes both correct, and
## keeps dead keys out of the saved JSON.
func update_prop(prop_id: String, patch: Dictionary) -> bool:
	var d := find_by_id(prop_id)
	if d.is_empty():
		return false
	# The record is a reference into `props`: merging into it is the update.
	for k in patch.keys():
		if patch[k] == null:
			d.erase(k)
		else:
			d[k] = patch[k]
	return true


func remove_prop(prop_id: String) -> bool:
	for i in props.size():
		if str((props[i] as Dictionary).get("id", "")) == prop_id:
			props.remove_at(i)
			_drop_index()
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
	_drop_index()
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
	_drop_index()


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
