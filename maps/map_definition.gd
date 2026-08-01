class_name MapDefinition
extends Resource

## Descriptor for a playable map (Phase 5). Use `TRUSTED_SCENE_PATHS` for save routing.

## Canonical Mars / aerial map (formerly root `main.tscn`).
const MARS_SCENE_CANONICAL: String = "res://scenes/maps/mars_aerial.tscn"
## Still accepted in save JSON and normalized to `MARS_SCENE_CANONICAL`.
const LEGACY_MARS_SCENE: String = "res://main.tscn"

## Canonical soak map scene (formerly `main- maybe unstable.tscn`).
const SOAK_SCENE_CANONICAL: String = "res://scenes/maps/soak_festival_2026.tscn"
## Still accepted in save JSON and normalized to `SOAK_SCENE_CANONICAL`.
const LEGACY_SOAK_SCENE: String = "res://main- maybe unstable.tscn"

## Reusable shell scene for ALL user-created location maps. Each user map is a
## MapDefinition .tres pointing here, carrying its own latitude/longitude; the
## TerrainLoader builds the terrain at runtime from those coords.
const GENERATED_SCENE: String = "res://scenes/maps/generated_location.tscn"

## Scenes allowed in save files and for `change_scene_to_file` from loads.
const TRUSTED_SCENE_PATHS: Array[String] = [
	MARS_SCENE_CANONICAL,
	SOAK_SCENE_CANONICAL,
	GENERATED_SCENE,
]

@export var display_name: String = "Map"
@export_file("*.tscn") var scene_path: String = ""
@export_multiline var description: String = ""
@export var scenario_config: ScenarioConfig
@export var thumbnail: Texture2D

## Geographic site for generated maps (scene_path == GENERATED_SCENE). Ignored by
## the two hand-built maps. extent_m == 0 lets the TerrainLoader use its default.
@export var latitude: float = 0.0
@export var longitude: float = 0.0
@export var half_extent_m: float = 0.0
## Hi-res DEM patch half-extent (m). 0 = TerrainLoader default (~1500 m).
@export var detail_half_extent_m: float = 0.0
## OSM buildings/vegetation fetch half-extent (m). 0 = TerrainLoader default (~1500 m).
@export var osm_half_extent_m: float = 0.0
## Slide OSM local geometry onto imagery (metres). +east / +north. Used when
## OSM plan year ≠ scar year on the aerial (classic Black Rock City case).
@export var osm_offset_east_m: float = 0.0
@export var osm_offset_north_m: float = 0.0
## When true (default), prefer on-disk terrain cache on load. Uncheck to force network refetch.
@export var load_from_cache: bool = true
## Unix time of last Start / Create launch (for map-select recency sort). 0 = never.
@export var last_loaded_unix: float = 0.0

## True when this definition drives the runtime-terrain generated scene.
func is_generated() -> bool:
	return normalize_scene_path(scene_path) == GENERATED_SCENE


func touch_last_loaded() -> void:
	last_loaded_unix = Time.get_unix_time_from_system()


static func normalize_scene_path(path: String) -> String:
	var p := path.strip_edges()
	if p == LEGACY_SOAK_SCENE:
		return SOAK_SCENE_CANONICAL
	if p == LEGACY_MARS_SCENE:
		return MARS_SCENE_CANONICAL
	return p


static func is_trusted_scene_path(path: String) -> bool:
	var p := normalize_scene_path(path.strip_edges())
	if p.is_empty():
		return false
	if not TRUSTED_SCENE_PATHS.has(p):
		return false
	if ResourceLoader.exists(p):
		return true
	if p == SOAK_SCENE_CANONICAL and ResourceLoader.exists(LEGACY_SOAK_SCENE):
		return true
	if p == MARS_SCENE_CANONICAL and ResourceLoader.exists(LEGACY_MARS_SCENE):
		return true
	return false


## Recursively verifies every dependency of `path` actually resolves on disk —
## not just `path` itself. `ResourceLoader.get_dependencies()` is NOT recursive
## (confirmed empirically: it lists only a scene's own direct ext_resources), so
## a bespoke map that nests a sub-scene like `Tree.tscn` would otherwise read as
## fully available just because `Tree.tscn` itself is present, while `Tree.tscn`'s
## own gitignored GLB dependency is silently missing underneath it. This is
## separate from `is_trusted_scene_path()` (which stays a cheap existence +
## allow-list check used for save-routing trust) — this is the stricter "is this
## map's art actually complete" question, used only when deciding whether to
## OFFER a map as playable (see location_picker_ui.gd). Guards against cycles
## via `_visited`; callers should not pass it themselves.
static func is_scene_fully_available(path: String, _visited: Dictionary = {}) -> bool:
	if path.is_empty() or _visited.has(path):
		return true
	_visited[path] = true
	if not ResourceLoader.exists(path):
		return false
	for dep in ResourceLoader.get_dependencies(path):
		var dep_path := _dependency_res_path(dep)
		if dep_path.is_empty() or not ResourceLoader.exists(dep_path):
			return false
		if dep_path.ends_with(".tscn") or dep_path.ends_with(".tres"):
			if not is_scene_fully_available(dep_path, _visited):
				return false
	return true


## get_dependencies() entries are formatted "uid::type::res://path" — the
## res:// path is always the last segment, regardless of how many "::" precede
## it (the type segment can be empty), so anchor on the last "res://" rather
## than a fixed split index.
static func _dependency_res_path(raw: String) -> String:
	var idx := raw.rfind("res://")
	return raw.substr(idx) if idx != -1 else ""


## Real `.tscn` path for `change_scene_to_file` after a slim export (only one soak/Mars variant packed).
static func resolve_playable_scene_path(normalized_path: String) -> String:
	var p := normalized_path.strip_edges()
	if p.is_empty():
		return p
	if p == SOAK_SCENE_CANONICAL:
		if ResourceLoader.exists(SOAK_SCENE_CANONICAL):
			return SOAK_SCENE_CANONICAL
		if ResourceLoader.exists(LEGACY_SOAK_SCENE):
			return LEGACY_SOAK_SCENE
	if p == MARS_SCENE_CANONICAL:
		if ResourceLoader.exists(MARS_SCENE_CANONICAL):
			return MARS_SCENE_CANONICAL
		if ResourceLoader.exists(LEGACY_MARS_SCENE):
			return LEGACY_MARS_SCENE
	if ResourceLoader.exists(p):
		return p
	return p


static func _canonical_fallback_scene_path() -> String:
	if ResourceLoader.exists(MARS_SCENE_CANONICAL):
		return MARS_SCENE_CANONICAL
	if ResourceLoader.exists(SOAK_SCENE_CANONICAL):
		return SOAK_SCENE_CANONICAL
	if ResourceLoader.exists(LEGACY_SOAK_SCENE):
		return SOAK_SCENE_CANONICAL
	if ResourceLoader.exists(LEGACY_MARS_SCENE):
		return MARS_SCENE_CANONICAL
	return MARS_SCENE_CANONICAL


## Canonical path for save JSON (`SOAK_SCENE_*` / `MARS_SCENE_*`), not necessarily the file that exists in a minimal export.
static func snapshot_scene_path(node: Node) -> String:
	if node == null:
		return _canonical_fallback_scene_path()
	var raw := String(node.scene_file_path).strip_edges()
	var p := normalize_scene_path(raw)
	if TRUSTED_SCENE_PATHS.has(p):
		if ResourceLoader.exists(p):
			return p
		if p == SOAK_SCENE_CANONICAL and ResourceLoader.exists(LEGACY_SOAK_SCENE):
			return SOAK_SCENE_CANONICAL
		if p == MARS_SCENE_CANONICAL and ResourceLoader.exists(LEGACY_MARS_SCENE):
			return MARS_SCENE_CANONICAL
	return _canonical_fallback_scene_path()
