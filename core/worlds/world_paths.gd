class_name WorldPaths
extends RefCounted

## The ONE resolver for where a WORLD's files live.
##
## A MAP is terrain + auto-generated OSM content (the terrain_cache, weather,
## the loc_*.tres registry) — shared, regenerable, never resolved here. A WORLD
## is a map plus everything the player built or simulated on it: props, lights,
## camps, sculpting, water, painted vegetation, NPC spaces, the graph, the peak
## score … Every subsystem that persists world state asks this class for its
## path instead of building "user://maps/<kind>_<lat>_<lon>.json" itself.
##
## Three storage modes:
##   * NO ACTIVE WORLD ("")  — selftests, `--script`, a harness run without
##     `--world`. Every path is BYTE-IDENTICAL to the pre-worlds literal (the
##     selftest pins each kind), so nothing that ran before changes.
##   * "legacy" — a world migrated from the old one-world-per-site layout. Its
##     data stays exactly where it always was (user://maps/...); nothing is
##     moved. Same paths as no world at all.
##   * "dir" — a new world, or a copy: user://worlds/<id>/<kind>.<ext>.
##
## Static state on purpose: the layer classes are pure `class_name` scripts
## that `--script` selftests load without autoloads, and naming an autoload
## from them breaks that compile (see CLAUDE.md, headless --script trap).

const LEGACY_DIR := "user://maps"
const GRAPH_AUTOSAVE_DIR := "user://saves/graph_autosave"
const SCORES_DIR := "user://scores"
const WORLDS_DIR := "user://worlds"

const STORAGE_NONE := ""
const STORAGE_LEGACY := "legacy"
const STORAGE_DIR := "dir"

## Every per-site WORLD file family: [kind, ext]. WorldStore copies, trashes
## and inventories a world from THIS list (plus the graph autosave and the
## scores file, which have their own layout); the selftest's coverage guard
## fails when a new "user://maps/" literal appears that is not routed here.
const KINDS: Array = [
	["placed_props", "json"],
	["placed_lights", "json"],
	["building_styles", "json"],
	["camp_areas", "json"],
	["festival_placement", "json"],
	["npc_spaces", "json"],
	["vegetation", "json"],
	["auto_veg_edits", "json"],
	["vegetation_style_v3", "json"],
	["microclimate", "json"],
	["peak_experience", "json"],
	["window_wall_viewpoint", "json"],
	["soi", "json"],
	["inventory", "json"],
	["labor", "json"],
	["terrain_tiles", "bin"],
	["terrain_edit", "json"],
	["earthworks", "json"],
	["user_water", "json"],
	["printed_objects", "json"],
	["water_features", "json"],
	["channel_tiles", "bin"],
	["channel_tiles", "json"],
	["poi", "json"],
	["ha_links", "json"],
	["climelapse_keys", "json"],
	["experiments", "json"],
	["deploy_schedule", "json"],
]

static var _world_id: String = ""
static var _root: String = ""
static var _storage: String = STORAGE_NONE
## The site key of the world's map: "<lat>_<lon>" tokens (generated map) or
## "scene_<basename>" (built-in scene). A request for a DIFFERENT key inside a
## dir world still gets its own file (suffixed), never the world's main file —
## a stale coordinate mid-load must not overwrite the world's data.
static var _world_key: String = ""
static var _root_made: bool = false
## SEALED while one world's scene tears down and the next one's has not
## started: the old scene's exit-time flushes (the graph view writes its
## autosave in _exit_tree, the loader saves props, …) would otherwise land in
## the NEW world's files, or — with no world active — on the legacy per-site
## files of the player's original build. Everything was flushed by
## WorldSession.save_now just before, so these writes are duplicates and go
## to a discard folder instead.
static var _sealed: bool = false
const DISCARD_DIR := "user://worlds/_discard"

## Test seam: the legacy directories, so the selftest can exercise legacy
## migration and copying against TEMP folders instead of the player's data.
static var _legacy_dir: String = LEGACY_DIR
static var _graph_dir: String = GRAPH_AUTOSAVE_DIR
static var _scores_dir: String = SCORES_DIR


## Activate a world for this session. `root` is the world's folder
## (user://worlds/<id>); `site_key` from site_key_for / scene_key_for.
static func set_active(world_id: String, root: String, storage: String, site_key: String) -> void:
	_sealed = false
	_world_id = world_id
	_root = root.trim_suffix("/")
	_storage = storage
	_world_key = site_key
	_root_made = false


static func clear_active() -> void:
	set_active("", "", STORAGE_NONE, "")


static func seal() -> void:
	_sealed = true
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DISCARD_DIR))


static func unseal() -> void:
	_sealed = false


static func is_sealed() -> bool:
	return _sealed


static func set_legacy_dirs_for_test(maps_dir: String, graph_dir: String, scores_dir: String) -> void:
	_legacy_dir = maps_dir.trim_suffix("/")
	_graph_dir = graph_dir.trim_suffix("/")
	_scores_dir = scores_dir.trim_suffix("/")


static func reset_legacy_dirs() -> void:
	set_legacy_dirs_for_test(LEGACY_DIR, GRAPH_AUTOSAVE_DIR, SCORES_DIR)


static func legacy_dir() -> String:
	return _legacy_dir


static func active_world_id() -> String:
	return _world_id


static func active_root() -> String:
	return _root


static func active_site_key() -> String:
	return _world_key


static func storage() -> String:
	return _storage


static func has_active_world() -> bool:
	return not _world_id.is_empty()


static func is_dir_world() -> bool:
	return _storage == STORAGE_DIR


## "<lat>_<lon>" coordinate tokens — the key every per-site file uses.
static func site_key_for(lat: float, lon: float) -> String:
	return "%s_%s" % [CoordToken.token(lat), CoordToken.token(lon)]


## "scene_<basename>" for a built-in scene path (or a bare tag).
static func scene_key_for(scene_key: String) -> String:
	var tag := scene_key.get_file().get_basename() if scene_key.contains("/") else scene_key
	if tag.is_empty():
		tag = "unknown_scene"
	return "scene_%s" % tag


## PURE: where `kind` lives for site `key` in a world with this storage/root.
## WorldStore uses it to address worlds that are not the active one.
static func path_in(kind: String, key: String, ext: String, storage_mode: String,
		world_root: String, world_key: String) -> String:
	var dot := ("." + ext) if not ext.is_empty() else ""
	if storage_mode == STORAGE_DIR:
		if key == world_key:
			return "%s/%s%s" % [world_root, kind, dot]
		return "%s/%s_%s%s" % [world_root, kind, key, dot]
	return "%s/%s_%s%s" % [_legacy_dir, kind, key, dot]


## PURE: a world's graph autosave. `key` is SystemGraphView's map key
## ("map_<lat>_<lon>" / "scene_<basename>").
static func graph_path_in(key: String, storage_mode: String, world_root: String, world_key: String) -> String:
	if storage_mode == STORAGE_DIR:
		if key.trim_prefix("map_") == world_key or key == world_key:
			return "%s/graph.graph.json" % world_root
		return "%s/graph_%s.graph.json" % [world_root, key]
	return "%s/%s.graph.json" % [_graph_dir, key]


## The graph key SystemGraphView computes for a world's site key.
static func graph_key_for_site(site_key: String) -> String:
	return site_key if site_key.begins_with("scene_") else "map_" + site_key


## PURE: the legacy scores file for a generated site (HighScoreStore layout).
static func legacy_scores_path(lat: float, lon: float) -> String:
	return "%s/%s.json" % [_scores_dir,
		("%.4f_%.4f" % [lat, lon]).replace(".", "p").replace("-", "m")]


# -- Active-world entry points (what the subsystems call) ---------------------

## The world file for `kind` under `key` (a site or scene key).
static func keyed_file(kind: String, key: String, ext: String) -> String:
	if _sealed:
		return path_in(kind, key, ext, STORAGE_DIR, DISCARD_DIR, _world_key)
	if _storage == STORAGE_DIR:
		_ensure_root()
	return path_in(kind, key, ext, _storage, _root, _world_key)


static func site_file(kind: String, lat: float, lon: float, ext: String = "json") -> String:
	return keyed_file(kind, site_key_for(lat, lon), ext)


static func scene_file(kind: String, scene_key: String, ext: String = "json") -> String:
	return keyed_file(kind, scene_key_for(scene_key), ext)


static func graph_autosave_path(key: String) -> String:
	if _sealed:
		return graph_path_in(key, STORAGE_DIR, DISCARD_DIR, _world_key)
	if _storage == STORAGE_DIR:
		_ensure_root()
	return graph_path_in(key, _storage, _root, _world_key)


## Challenge high scores (HighScoreStore) — a world's own scoreboard.
static func scores_path(legacy_path: String) -> String:
	if _sealed:
		return "%s/scores.json" % DISCARD_DIR
	if _storage == STORAGE_DIR:
		_ensure_root()
		return "%s/scores.json" % _root
	return legacy_path


static func _ensure_root() -> void:
	if _root_made or _root.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_root))
	_root_made = true
