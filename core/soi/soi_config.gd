class_name SoiConfig
extends RefCounted

const VERSION := 1
const DEFAULT_RADIUS_M := 200.0
const MIN_RADIUS_M := 25.0
const MAX_RADIUS_M := 2000.0

var center_x: float = 0.0
var center_z: float = 0.0
var radius_m: float = DEFAULT_RADIUS_M


static func defaults() -> SoiConfig:
	return SoiConfig.new()


static func save_path_for_map(lat: float, lon: float) -> String:
	return WorldPaths.site_file("soi", lat, lon)


static func load_for_map(lat: float, lon: float) -> SoiConfig:
	var cfg := defaults()
	var path := save_path_for_map(lat, lon)
	if not FileAccess.file_exists(path):
		return cfg
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return cfg
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if parsed is Dictionary:
		cfg.deserialize(parsed as Dictionary)
	return cfg


func save_for_map(lat: float, lon: float) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://maps"))
	var f := FileAccess.open(save_path_for_map(lat, lon), FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(serialize()))


func serialize() -> Dictionary:
	return {
		"version": VERSION,
		"center_x": center_x,
		"center_z": center_z,
		"radius_m": radius_m,
	}


func deserialize(data: Dictionary) -> void:
	center_x = float(data.get("center_x", 0.0))
	center_z = float(data.get("center_z", 0.0))
	radius_m = clampf(float(data.get("radius_m", DEFAULT_RADIUS_M)), MIN_RADIUS_M, MAX_RADIUS_M)


func duplicate_config() -> SoiConfig:
	var c := SoiConfig.new()
	c.center_x = center_x
	c.center_z = center_z
	c.radius_m = radius_m
	return c
