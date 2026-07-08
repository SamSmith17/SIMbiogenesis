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

## True when this definition drives the runtime-terrain generated scene.
func is_generated() -> bool:
	return normalize_scene_path(scene_path) == GENERATED_SCENE


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
