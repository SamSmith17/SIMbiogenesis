class_name TerrainCacheSettings
extends RefCounted

## Reads/writes terrain cache on/off from user://terrain_config.cfg
## ([terrain] cache_enabled). Helpers delete cached files for a site so the
## next fetch bypasses disk.

const CONFIG_PATH := "user://terrain_config.cfg"

const DEM_DIR := "user://terrain_cache/dem"
const IMG_DIR := "user://terrain_cache/imagery"
const OSM_DIR := "user://terrain_cache/osm_vectors"
const OSM_VEG_DIR := "user://terrain_cache/osm_vegetation"


static func cache_enabled() -> bool:
	if not FileAccess.file_exists(CONFIG_PATH):
		return true
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		return true
	return bool(cfg.get_value("terrain", "cache_enabled", true))


static func set_cache_enabled(on: bool) -> void:
	var cfg := ConfigFile.new()
	if FileAccess.file_exists(CONFIG_PATH):
		cfg.load(CONFIG_PATH)
	cfg.set_value("terrain", "cache_enabled", on)
	cfg.save(CONFIG_PATH)


## Stable substring shared by all cache keys for one map centre.
static func coord_token(lat: float, lon: float) -> String:
	return "%.4f_%.4f" % [lat, lon]


static func invalidate_dem(lat: float, lon: float) -> int:
	return _delete_matching(DEM_DIR, coord_token(lat, lon), "dem_")


static func save_meta_extents(lat: float, lon: float, half_m: float, detail_m: float, osm_m: float,
		osm_offset_east_m: float = 0.0, osm_offset_north_m: float = 0.0) -> void:
	var path := "user://terrain_cache/extents_%s.json" % coord_token(lat, lon)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://terrain_cache"))
	var data := {}
	if FileAccess.file_exists(path):
		var txt := FileAccess.get_file_as_string(path)
		var p = JSON.parse_string(txt)
		if p is Dictionary:
			data = p
	data["half_extent_m"] = half_m
	data["detail_half_extent_m"] = detail_m
	data["osm_half_extent_m"] = osm_m
	data["osm_offset_east_m"] = osm_offset_east_m
	data["osm_offset_north_m"] = osm_offset_north_m
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(data))


static func get_meta_extents(lat: float, lon: float) -> Dictionary:
	var path := "user://terrain_cache/extents_%s.json" % coord_token(lat, lon)
	if FileAccess.file_exists(path):
		var txt := FileAccess.get_file_as_string(path)
		var p = JSON.parse_string(txt)
		if p is Dictionary:
			return p
	return {}


static func invalidate_imagery(lat: float, lon: float) -> int:
	return _delete_matching(IMG_DIR, coord_token(lat, lon), "img_")


static func invalidate_osm_vectors(lat: float, lon: float) -> int:
	return _delete_matching(OSM_DIR, coord_token(lat, lon), "osm_")


static func invalidate_osm_vegetation(lat: float, lon: float) -> int:
	return _delete_matching(OSM_VEG_DIR, coord_token(lat, lon), "osmveg_")


static func invalidate_all(lat: float, lon: float) -> int:
	var n := 0
	n += invalidate_dem(lat, lon)
	n += invalidate_imagery(lat, lon)
	n += invalidate_osm_vectors(lat, lon)
	n += invalidate_osm_vegetation(lat, lon)
	return n


## Delete user-painted vegetation + style sidecars for one map site.
static func invalidate_user_vegetation_edits(lat: float, lon: float) -> int:
	var token := coord_token(lat, lon)
	var removed := 0
	for path in [
		"user://maps/vegetation_%s_%s.json" % [token, token],
		"user://maps/auto_veg_edits_%s_%s.json" % [token, token],
		"user://maps/vegetation_style_%s_%s.json" % [token, token],
	]:
		if FileAccess.file_exists(path):
			if DirAccess.remove_absolute(ProjectSettings.globalize_path(path)) == OK:
				removed += 1
	return removed


## True when base DEM + base imagery cache files exist for this site (warm reload).
static func has_warm_cache(lat: float, lon: float) -> bool:
	if not cache_enabled():
		return false
	var token := coord_token(lat, lon)
	return _dir_has_token(DEM_DIR, token, "dem_") and _dir_has_token(IMG_DIR, token, "img_")


static func _dir_has_token(dir_path: String, token: String, prefix: String) -> bool:
	if token.is_empty():
		return false
	var da := DirAccess.open(dir_path)
	if da == null:
		return false
	da.list_dir_begin()
	var fn := da.get_next()
	while fn != "":
		if not da.current_is_dir() and token in fn and fn.begins_with(prefix):
			da.list_dir_end()
			return true
		fn = da.get_next()
	da.list_dir_end()
	return false


static func _delete_matching(dir_path: String, token: String, prefix: String = "") -> int:
	if token.is_empty():
		return 0
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir_path))
	var da := DirAccess.open(dir_path)
	if da == null:
		return 0
	var removed := 0
	da.list_dir_begin()
	var fn := da.get_next()
	while fn != "":
		if not da.current_is_dir() and token in fn:
			if prefix.is_empty() or fn.begins_with(prefix):
				var path := "%s/%s" % [dir_path, fn]
				if DirAccess.remove_absolute(ProjectSettings.globalize_path(path)) == OK:
					removed += 1
		fn = da.get_next()
	da.list_dir_end()
	return removed
