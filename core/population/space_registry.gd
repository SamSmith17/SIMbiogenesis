class_name SpaceRegistry
extends RefCounted

## Per-map registry of player-tagged "spaces" — world objects assigned a
## SpaceTypes role (restroom / kitchen / sleeping / water point) that NPC
## agents wayfind to. Single source of truth: tags are NOT mirrored into
## prop records or BuildingStyleLayer (styling a building de-merges it from
## the OSM mesh — a perf side effect tagging must not trigger).
##
## Target kinds:
##   {"kind": "prop",     "prop_id": "<PlacedPropLayer id>"}
##   {"kind": "building", "building_tag": "<BuildingBuilder.building_tag>"}
##   {"kind": "area",     "poly": [[x, z], ...]}          # reserved for v2
##
## Occupancy (which agents currently claim a space) is runtime-only and is
## never serialized. Persistence follows the PlacedPropLayer pattern:
## user://maps/npc_spaces_<lat>_<lon>.json (or _scene_<tag>.json).

const VERSION := 1
const MAX_SPACES := 200
const DEFAULT_CAPACITY := 2

var spaces: Array = []
var _occupancy: Dictionary = {}  # space_id -> Array[String] agent ids (runtime only)


static func create_empty() -> SpaceRegistry:
	var layer := SpaceRegistry.new()
	layer.spaces = []
	return layer


# --- persistence (PlacedPropLayer idiom) ------------------------------------

func save_path_for_map(lat: float, lon: float) -> String:
	return "user://maps/npc_spaces_%s_%s.json" % [CoordToken.token(lat), CoordToken.token(lon)]


func save_path_for_scene(scene_key: String) -> String:
	var tag := scene_key.get_file().get_basename() if scene_key.contains("/") else scene_key
	if tag.is_empty():
		tag = "unknown_scene"
	return "user://maps/npc_spaces_scene_%s.json" % tag


func save(lat: float, lon: float) -> void:
	_save_to(save_path_for_map(lat, lon))


func load_for_map(lat: float, lon: float) -> bool:
	return _load_from(save_path_for_map(lat, lon))


func save_for_scene(scene_key: String) -> void:
	_save_to(save_path_for_scene(scene_key))


func load_for_scene(scene_key: String) -> bool:
	return _load_from(save_path_for_scene(scene_key))


func _save_to(path: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://maps"))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(serialize()))


func _load_from(path: String) -> bool:
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
	return {"version": VERSION, "spaces": spaces.duplicate(true)}


func deserialize(data: Dictionary) -> void:
	spaces = []
	for item in data.get("spaces", []):
		if item is Dictionary and SpaceTypes.is_valid(str((item as Dictionary).get("space_type", ""))):
			spaces.append(item)
	_occupancy = {}


# --- record CRUD ------------------------------------------------------------

func find_by_id(space_id: String) -> Dictionary:
	for item in spaces:
		if item is Dictionary and str(item.get("id", "")) == space_id:
			return item
	return {}


## The space record whose target matches `target` (kind + identifying key).
func space_for_target(target: Dictionary) -> Dictionary:
	for item in spaces:
		if item is Dictionary and _targets_equal((item as Dictionary).get("target", {}), target):
			return item
	return {}


## Upsert: assign `space_type` to `target` (creating a record if needed).
## Empty space_type removes the tag. Returns the space id ("" if removed
## or invalid).
func set_space_type(target: Dictionary, space_type: String,
		capacity: int = DEFAULT_CAPACITY, label: String = "") -> String:
	var existing := space_for_target(target)
	if space_type.is_empty():
		if not existing.is_empty():
			remove_space(str(existing.get("id", "")))
		return ""
	if not SpaceTypes.is_valid(space_type):
		return ""
	if not existing.is_empty():
		existing["space_type"] = space_type
		existing["capacity"] = maxi(capacity, 1)
		if not label.is_empty():
			existing["label"] = label
		return str(existing.get("id", ""))
	if spaces.size() >= MAX_SPACES:
		return ""
	var rec := {
		"id": _new_id(),
		"space_type": space_type,
		"target": target.duplicate(true),
		"capacity": maxi(capacity, 1),
		"label": label,
	}
	spaces.append(rec)
	return str(rec["id"])


func remove_space(space_id: String) -> bool:
	for i in spaces.size():
		if str((spaces[i] as Dictionary).get("id", "")) == space_id:
			spaces.remove_at(i)
			_occupancy.erase(space_id)
			return true
	return false


func _new_id() -> String:
	var max_n := 0
	for item in spaces:
		var sid := str((item as Dictionary).get("id", ""))
		if sid.begins_with("sp_"):
			max_n = maxi(max_n, int(sid.substr(3)))
	return "sp_%d" % (max_n + 1)


func _targets_equal(a: Dictionary, b: Dictionary) -> bool:
	if str(a.get("kind", "")) != str(b.get("kind", "")):
		return false
	match str(a.get("kind", "")):
		"prop":
			return str(a.get("prop_id", "")) == str(b.get("prop_id", ""))
		"building":
			return str(a.get("building_tag", "")) == str(b.get("building_tag", ""))
		"area":
			return a.get("poly", []) == b.get("poly", [])
	return false


# --- queries ----------------------------------------------------------------

func spaces_of_type(space_type: String) -> Array:
	var out: Array = []
	for item in spaces:
		if item is Dictionary and str(item.get("space_type", "")) == space_type:
			out.append(item)
	return out


## Nearest space of `space_type` to `pos`, resolving world positions through
## `pos_of` (space Dictionary -> Vector2 world XZ, or null for dangling
## targets, which are skipped). `require_free` skips spaces at capacity.
## Returns {} when nothing qualifies.
func nearest_space_by(space_type: String, pos: Vector2, pos_of: Callable,
		require_free: bool = true) -> Dictionary:
	var best: Dictionary = {}
	var best_d := INF
	for item in spaces_of_type(space_type):
		var space: Dictionary = item
		if require_free and not has_free_capacity(str(space.get("id", ""))):
			continue
		var p: Variant = pos_of.call(space)
		if not (p is Vector2):
			continue
		var d := ((p as Vector2) - pos).length_squared()
		if d < best_d:
			best_d = d
			best = space
	return best


## Runtime convenience: nearest_space_by with the live-world resolver.
func nearest_space(space_type: String, pos: Vector2, main: Node,
		require_free: bool = true) -> Dictionary:
	return nearest_space_by(space_type, pos,
			func(space: Dictionary) -> Variant: return resolve_position(space, main),
			require_free)


## World XZ of a space's target, or null when the target no longer exists
## (deleted prop, missing building) — callers must skip null.
func resolve_position(space: Dictionary, main: Node) -> Variant:
	var target: Dictionary = space.get("target", {})
	match str(target.get("kind", "")):
		"prop":
			var rec: Dictionary = PlacedPropService.get_prop_record(main, str(target.get("prop_id", "")))
			if rec.is_empty():
				return null
			return Vector2(float(rec.get("x", 0.0)), float(rec.get("z", 0.0)))
		"building":
			var loader := TerrainSurfaceQuery.find_terrain_loader(main)
			if loader == null or not loader.has_method("building_centroid_by_tag"):
				return null
			return loader.call("building_centroid_by_tag", str(target.get("building_tag", "")))
		"area":
			var poly: Array = target.get("poly", [])
			if poly.is_empty():
				return null
			var c := Vector2.ZERO
			for p in poly:
				if p is Array and (p as Array).size() >= 2:
					c += Vector2(float((p as Array)[0]), float((p as Array)[1]))
			return c / float(poly.size())
	return null


## Drop records whose target no longer resolves (call before save).
func prune_dangling(main: Node) -> int:
	var removed := 0
	for i in range(spaces.size() - 1, -1, -1):
		if resolve_position(spaces[i], main) == null:
			_occupancy.erase(str((spaces[i] as Dictionary).get("id", "")))
			spaces.remove_at(i)
			removed += 1
	return removed


# --- runtime occupancy (never serialized) -----------------------------------

func occupant_count(space_id: String) -> int:
	return (_occupancy.get(space_id, []) as Array).size()


func has_free_capacity(space_id: String) -> bool:
	var rec := find_by_id(space_id)
	if rec.is_empty():
		return false
	return occupant_count(space_id) < maxi(int(rec.get("capacity", DEFAULT_CAPACITY)), 1)


func claim(space_id: String, agent_id: String) -> bool:
	var occ: Array = _occupancy.get(space_id, [])
	if agent_id in occ:
		return true
	if not has_free_capacity(space_id):
		return false
	occ.append(agent_id)
	_occupancy[space_id] = occ
	return true


func release(space_id: String, agent_id: String) -> void:
	var occ: Array = _occupancy.get(space_id, [])
	occ.erase(agent_id)
	if occ.is_empty():
		_occupancy.erase(space_id)
	else:
		_occupancy[space_id] = occ


func release_all_for_agent(agent_id: String) -> void:
	for sid in _occupancy.keys():
		release(str(sid), agent_id)


func clear_occupancy() -> void:
	_occupancy = {}
