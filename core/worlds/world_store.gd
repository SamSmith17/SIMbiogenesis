class_name WorldStore
extends RefCounted

## Worlds: a MAP plus everything built or simulated on it.
##
## One folder per world, `user://worlds/<id>/`, holding:
##   world.json     — the record (name, map reference, timestamps, summary)
##   snapshot.json  — player / clock / solar / rules (main.build_save_snapshot,
##                    minus the graph, which lives in the world's graph file)
##   thumb.png      — a viewport capture from the last save
##   <kind>.<ext>   — the world's data files (dir storage only; see WorldPaths)
##   assets/        — vendored copies of referenced library files (WorldAssets)
##
## A "legacy" world is one migrated from the pre-worlds layout: its record and
## snapshot live here, but its data files stay exactly where they always were
## under user://maps. Nothing of the player's is ever moved by a migration.
##
## Every function takes the worlds root as a parameter (default
## WorldPaths.WORLDS_DIR) so the selftest runs against a TEMP folder.
## Deleting a world MOVES it to <root>/_trash — nothing here hard-deletes.

const VERSION := 1
const RECORD_FILE := "world.json"
const SNAPSHOT_FILE := "snapshot.json"
const THUMB_FILE := "thumb.png"
const TRASH_DIR := "_trash"
const MIGRATED_FILE := "migrated.json"
## Files of a world folder that are not world DATA (copy/inventory skip them
## or treat them separately).
const META_FILES := [RECORD_FILE, SNAPSHOT_FILE, THUMB_FILE]


# -- Ids, names, keys ----------------------------------------------------------

static func new_id() -> String:
	var t := int(Time.get_unix_time_from_system())
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	return "w%x%04x" % [t, rng.randi() & 0xffff]


## What the player sees: their own name, else the map's location label, else
## the coordinates.
static func display_name(rec: Dictionary) -> String:
	var n := str(rec.get("name", "")).strip_edges()
	if not n.is_empty():
		return n
	var map: Dictionary = rec.get("map", {}) if rec.get("map", {}) is Dictionary else {}
	var label := str(map.get("label", "")).strip_edges()
	if not label.is_empty():
		return label
	if is_generated_map(map):
		return "%.4f, %.4f" % [float(map.get("lat", 0.0)), float(map.get("lon", 0.0))]
	return str(map.get("scene_path", "World")).get_file().get_basename()


static func is_generated_map(map: Dictionary) -> bool:
	return MapDefinition.normalize_scene_path(str(map.get("scene_path", ""))) \
		== MapDefinition.GENERATED_SCENE


## The site key the world's files are filed under (WorldPaths).
static func site_key_of(rec: Dictionary) -> String:
	var map: Dictionary = rec.get("map", {}) if rec.get("map", {}) is Dictionary else {}
	if is_generated_map(map):
		return WorldPaths.site_key_for(float(map.get("lat", 0.0)), float(map.get("lon", 0.0)))
	return WorldPaths.scene_key_for(MapDefinition.normalize_scene_path(str(map.get("scene_path", ""))))


## The map half of a record, from a MapDefinition.
static func map_ref_from_definition(md: MapDefinition, map_def_path: String = "") -> Dictionary:
	return {
		"scene_path": MapDefinition.normalize_scene_path(md.scene_path),
		"lat": md.latitude,
		"lon": md.longitude,
		"label": md.display_name,
		"half_extent_m": md.half_extent_m,
		"detail_half_extent_m": md.detail_half_extent_m,
		"osm_half_extent_m": md.osm_half_extent_m,
		"map_def_path": map_def_path,
	}


# -- Folders -------------------------------------------------------------------

static func world_dir(id: String, root: String = WorldPaths.WORLDS_DIR) -> String:
	return "%s/%s" % [root.trim_suffix("/"), id]


static func record_path(id: String, root: String = WorldPaths.WORLDS_DIR) -> String:
	return "%s/%s" % [world_dir(id, root), RECORD_FILE]


static func snapshot_path(id: String, root: String = WorldPaths.WORLDS_DIR) -> String:
	return "%s/%s" % [world_dir(id, root), SNAPSHOT_FILE]


static func thumb_path(id: String, root: String = WorldPaths.WORLDS_DIR) -> String:
	return "%s/%s" % [world_dir(id, root), THUMB_FILE]


# -- Records -------------------------------------------------------------------

static func create(map: Dictionary, name: String = "", storage: String = WorldPaths.STORAGE_DIR,
		root: String = WorldPaths.WORLDS_DIR) -> Dictionary:
	var now := Time.get_unix_time_from_system()
	var rec := {
		"version": VERSION,
		"id": new_id(),
		"name": name.strip_edges(),
		"storage": storage,
		"map": map.duplicate(true),
		"created_unix": now,
		"last_played_unix": now,
		"last_saved_unix": 0.0,
		"playtime_s": 0.0,
		"game_time": {},
		"summary": {},
	}
	save_record(rec, root)
	return rec


static func save_record(rec: Dictionary, root: String = WorldPaths.WORLDS_DIR) -> bool:
	var id := str(rec.get("id", ""))
	if id.is_empty():
		return false
	var dir := world_dir(id, root)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	return _write_json(record_path(id, root), rec)


static func get_world(id: String, root: String = WorldPaths.WORLDS_DIR) -> Dictionary:
	if id.is_empty():
		return {}
	var d := _read_json(record_path(id, root))
	return d if str(d.get("id", "")) == id else {}


## Every world, most recently played first. Harness scratch worlds
## ("scratch": true) are hidden unless asked for.
static func list(root: String = WorldPaths.WORLDS_DIR, include_scratch: bool = false) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var da := DirAccess.open(root)
	if da == null:
		return out
	for sub in da.get_directories():
		if sub.begins_with("_") or sub.begins_with("."):
			continue
		var rec := get_world(sub, root)
		if not rec.is_empty() and (include_scratch or not bool(rec.get("scratch", false))):
			out.append(rec)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ta := float(a.get("last_played_unix", 0.0))
		var tb := float(b.get("last_played_unix", 0.0))
		if ta == tb:
			return str(a.get("id", "")) < str(b.get("id", ""))
		return ta > tb)
	return out


## Worlds standing on the same map (same site key).
static func worlds_on_map(rec_or_map: Dictionary, root: String = WorldPaths.WORLDS_DIR) -> Array[Dictionary]:
	var key := site_key_of(rec_or_map if rec_or_map.has("map") else {"map": rec_or_map})
	var out: Array[Dictionary] = []
	for w in list(root):
		if site_key_of(w) == key:
			out.append(w)
	return out


static func rename(id: String, new_name: String, root: String = WorldPaths.WORLDS_DIR) -> bool:
	var rec := get_world(id, root)
	if rec.is_empty():
		return false
	rec["name"] = new_name.strip_edges()
	return save_record(rec, root)


static func touch_played(id: String, root: String = WorldPaths.WORLDS_DIR) -> void:
	var rec := get_world(id, root)
	if rec.is_empty():
		return
	rec["last_played_unix"] = Time.get_unix_time_from_system()
	save_record(rec, root)


# -- Activation ------------------------------------------------------------------

## Point WorldPaths at this world for the session.
static func activate(rec: Dictionary, root: String = WorldPaths.WORLDS_DIR) -> void:
	var id := str(rec.get("id", ""))
	if id.is_empty():
		WorldPaths.clear_active()
		return
	WorldPaths.set_active(id, world_dir(id, root), str(rec.get("storage", WorldPaths.STORAGE_DIR)),
		site_key_of(rec))


# -- Snapshot ------------------------------------------------------------------

static func write_snapshot(id: String, snap: Dictionary, root: String = WorldPaths.WORLDS_DIR) -> bool:
	if id.is_empty():
		return false
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(world_dir(id, root)))
	return _write_json(snapshot_path(id, root), snap)


static func read_snapshot(id: String, root: String = WorldPaths.WORLDS_DIR) -> Dictionary:
	return _read_json(snapshot_path(id, root))


# -- Inventory of a world's data files ---------------------------------------------

## Every DATA file this world owns that exists on disk, as {kind_tag: path}.
## kind_tag is stable across storage modes ("placed_props.json",
## "graph.graph.json", "scores.json", …) so duplicate() can map a legacy
## world's files onto a dir world's layout one to one.
static func data_files(rec: Dictionary, root: String = WorldPaths.WORLDS_DIR) -> Dictionary:
	var out := {}
	var id := str(rec.get("id", ""))
	var storage := str(rec.get("storage", WorldPaths.STORAGE_DIR))
	var key := site_key_of(rec)
	var wroot := world_dir(id, root)
	for k in WorldPaths.KINDS:
		var kind := str(k[0])
		var ext := str(k[1])
		var p := WorldPaths.path_in(kind, key, ext, storage, wroot, key)
		if FileAccess.file_exists(p):
			out["%s.%s" % [kind, ext]] = p
	var gp := WorldPaths.graph_path_in(WorldPaths.graph_key_for_site(key), storage, wroot, key)
	if FileAccess.file_exists(gp):
		out["graph.graph.json"] = gp
	var map: Dictionary = rec.get("map", {}) if rec.get("map", {}) is Dictionary else {}
	var sp := ("%s/scores.json" % wroot) if storage == WorldPaths.STORAGE_DIR \
		else (WorldPaths.legacy_scores_path(float(map.get("lat", 0.0)), float(map.get("lon", 0.0)))
			if is_generated_map(map) else "")
	if not sp.is_empty() and FileAccess.file_exists(sp):
		out["scores.json"] = sp
	return out


## Where a kind_tag from data_files() lands in a DIR world.
static func dir_path_for_tag(tag: String, wroot: String) -> String:
	return "%s/%s" % [wroot, tag]


# -- Duplicate / delete ------------------------------------------------------------

## Copy a world (any storage) into a NEW dir-storage world. The caller flushes
## live state first if `id` is the running world. Returns the new record, or {}.
static func duplicate_world(id: String, new_name: String, root: String = WorldPaths.WORLDS_DIR) -> Dictionary:
	var src := get_world(id, root)
	if src.is_empty():
		return {}
	var files := data_files(src, root)
	var dst := create(src.get("map", {}), new_name, WorldPaths.STORAGE_DIR, root)
	var did := str(dst["id"])
	var droot := world_dir(did, root)
	for tag in files:
		_copy_file(str(files[tag]), dir_path_for_tag(str(tag), droot))
	var sroot := world_dir(id, root)
	for meta in [SNAPSHOT_FILE, THUMB_FILE]:
		var sp := "%s/%s" % [sroot, meta]
		if FileAccess.file_exists(sp):
			_copy_file(sp, "%s/%s" % [droot, meta])
	_copy_tree("%s/assets" % sroot, "%s/assets" % droot)
	for k in ["playtime_s", "game_time", "summary", "last_saved_unix"]:
		if src.has(k):
			dst[k] = src[k]
	dst["copied_from"] = id
	save_record(dst, root)
	return dst


## Move a world into the trash (never hard-deleted). A legacy world's data
## files are moved there too, so the site really is free afterwards.
static func trash(id: String, root: String = WorldPaths.WORLDS_DIR) -> bool:
	var rec := get_world(id, root)
	if rec.is_empty():
		return false
	var stamp := int(Time.get_unix_time_from_system())
	var tdir := "%s/%s/%s_%d" % [root.trim_suffix("/"), TRASH_DIR, id, stamp]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(tdir))
	if str(rec.get("storage", "")) == WorldPaths.STORAGE_LEGACY:
		var files := data_files(rec, root)
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(tdir + "/legacy"))
		for tag in files:
			var p := str(files[tag])
			_move_file(p, "%s/legacy/%s" % [tdir, p.get_file()])
	return _move_file(world_dir(id, root), "%s/world" % tdir)


## Remove a folder tree this code created (harness scratch worlds only —
## player worlds go to the trash instead).
static func remove_tree(dir: String) -> void:
	var da := DirAccess.open(dir)
	if da == null:
		return
	for sub in da.get_directories():
		remove_tree("%s/%s" % [dir, sub])
	for fn in da.get_files():
		DirAccess.remove_absolute(ProjectSettings.globalize_path("%s/%s" % [dir, fn]))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir))


## Delete every leftover harness scratch world (a killed run never cleans up).
static func purge_scratch(root: String = WorldPaths.WORLDS_DIR) -> int:
	var n := 0
	for rec in list(root, true):
		if bool(rec.get("scratch", false)):
			remove_tree(world_dir(str(rec.get("id", "")), root))
			n += 1
	return n


# -- Legacy migration --------------------------------------------------------------

## One-time, idempotent: create a LEGACY world for every site that already has
## world data in the old layout (user://maps/*_<lat>_<lon>.* or a graph
## autosave). Nothing is moved or copied. A site is migrated at most once —
## recorded in <root>/migrated.json — so deleting the migrated world later
## does not resurrect it. `maps` are the known MapDefinitions as
## [{md: MapDefinition, path: String}], built-ins included.
## `legacy_autosave` (the old global autosave.save.json payload) becomes the
## matching world's starting snapshot.
static func migrate_legacy(maps: Array, legacy_autosave: Dictionary = {},
		root: String = WorldPaths.WORLDS_DIR) -> Array[Dictionary]:
	var created: Array[Dictionary] = []
	var done := _read_json("%s/%s" % [root, MIGRATED_FILE])
	var sites: Dictionary = done.get("sites", {}) if done.get("sites", {}) is Dictionary else {}
	for entry in maps:
		if not (entry is Dictionary):
			continue
		var md: MapDefinition = (entry as Dictionary).get("md") as MapDefinition
		if md == null:
			continue
		var map := map_ref_from_definition(md, str((entry as Dictionary).get("path", "")))
		var probe := {"id": "_probe", "storage": WorldPaths.STORAGE_LEGACY, "map": map}
		var key := site_key_of(probe)
		if sites.has(key):
			continue
		if data_files(probe, root).is_empty():
			continue
		var rec := create(map, "", WorldPaths.STORAGE_LEGACY, root)
		rec["created_unix"] = md.last_loaded_unix if md.last_loaded_unix > 0.0 else rec["created_unix"]
		rec["last_played_unix"] = md.last_loaded_unix
		rec["migrated"] = true
		if not legacy_autosave.is_empty() and _autosave_matches(legacy_autosave, map):
			var snap := legacy_autosave.duplicate(true)
			snap.erase("system_graph")  # the graph lives in the world's graph file
			snap["world_id"] = rec["id"]
			write_snapshot(str(rec["id"]), snap, root)
			rec["playtime_s"] = float(legacy_autosave.get("playtime_seconds", 0.0))
			rec["game_time"] = _game_time_of(legacy_autosave)
			var at := float(legacy_autosave.get("created_at_unix", 0.0))
			if at > float(rec["last_played_unix"]):
				rec["last_played_unix"] = at
		save_record(rec, root)
		sites[key] = str(rec["id"])
		created.append(rec)
	done["sites"] = sites
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(root))
	_write_json("%s/%s" % [root, MIGRATED_FILE], done)
	return created


static func _autosave_matches(snap: Dictionary, map: Dictionary) -> bool:
	var scene := MapDefinition.normalize_scene_path(str(snap.get("scene_path", "")))
	if scene != MapDefinition.normalize_scene_path(str(map.get("scene_path", ""))):
		return false
	if not is_generated_map(map):
		return true
	var m: Dictionary = snap.get("main", {}) if snap.get("main", {}) is Dictionary else {}
	return absf(float(m.get("latitude", 999.0)) - float(map.get("lat", 0.0))) < 1e-4 \
		and absf(float(m.get("longitude", 999.0)) - float(map.get("lon", 0.0))) < 1e-4


## {year, month, day, day_time} from a snapshot, for the world list.
static func _game_time_of(snap: Dictionary) -> Dictionary:
	var m: Dictionary = snap.get("main", {}) if snap.get("main", {}) is Dictionary else {}
	if m.is_empty():
		return {}
	return {"year": int(m.get("year", 0)), "month": int(m.get("month", 0)),
		"day": int(m.get("day", 0)), "day_time": float(m.get("day_time", 0.0))}


## Fold a fresh snapshot into the record (list columns) and save both.
static func record_save(id: String, snap: Dictionary, summary: Dictionary = {},
		root: String = WorldPaths.WORLDS_DIR) -> bool:
	var rec := get_world(id, root)
	if rec.is_empty():
		return false
	var s := snap.duplicate(true)
	s.erase("system_graph")
	s["world_id"] = id
	if not write_snapshot(id, s, root):
		return false
	var now := Time.get_unix_time_from_system()
	rec["last_saved_unix"] = now
	rec["last_played_unix"] = now
	rec["playtime_s"] = float(snap.get("playtime_seconds", rec.get("playtime_s", 0.0)))
	rec["game_time"] = _game_time_of(snap)
	if not summary.is_empty():
		rec["summary"] = summary
	var extras: Variant = snap.get("world_extras", {})
	if extras is Dictionary and (extras as Dictionary).get("terrain_imagery", null) is Dictionary:
		rec["terrain_imagery"] = ((extras as Dictionary)["terrain_imagery"] as Dictionary).duplicate()
	return save_record(rec, root)


# -- File helpers ------------------------------------------------------------------

static func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


## Write via a temp file + rename so a crash mid-write never leaves a torn
## record or snapshot.
static func _write_json(path: String, data: Dictionary) -> bool:
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	var g_tmp := ProjectSettings.globalize_path(tmp)
	var g_dst := ProjectSettings.globalize_path(path)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(g_dst)
	return DirAccess.rename_absolute(g_tmp, g_dst) == OK


static func _copy_file(src: String, dst: String) -> bool:
	if not FileAccess.file_exists(src):
		return false
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dst.get_base_dir()))
	return DirAccess.copy_absolute(ProjectSettings.globalize_path(src),
		ProjectSettings.globalize_path(dst)) == OK


static func _copy_tree(src_dir: String, dst_dir: String) -> void:
	var da := DirAccess.open(src_dir)
	if da == null:
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dst_dir))
	for fn in da.get_files():
		_copy_file("%s/%s" % [src_dir, fn], "%s/%s" % [dst_dir, fn])
	for sub in da.get_directories():
		_copy_tree("%s/%s" % [src_dir, sub], "%s/%s" % [dst_dir, sub])


static func _move_file(src: String, dst: String) -> bool:
	var g_src := ProjectSettings.globalize_path(src)
	if not (FileAccess.file_exists(src) or DirAccess.dir_exists_absolute(g_src)):
		return false
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dst.get_base_dir()))
	return DirAccess.rename_absolute(g_src, ProjectSettings.globalize_path(dst)) == OK
