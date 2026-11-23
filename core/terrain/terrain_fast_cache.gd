class_name TerrainFastCache
extends RefCounted

## Regenerable binary cache accelerator in user://terrain_cache/_fast/ for large
## JSON terrain caches (512² float32 DEMs and deserialized OSM vector/vegetation
## payloads).
##
## Why this lives in `_fast/`:
##   - AssetPackCatalog.TERRAIN_CACHE_SUBDIRS packs only the canonical subdirs
##     (dem, imagery, osm_vectors, osm_vegetation, ai_imagery, mapillary), so
##     `_fast/` never bloats `.simbiopack` exports or trips pack format checks.
##   - Every `.bin` records the source `.json` file's byte length and modified
##     timestamp. Any edit, replacement or deletion of the `.json` automatically
##     invalidates the `.bin` without needing manual cache-version bumps.
##   - Payloads are decoded strictly with `bytes_to_var` (objects disabled).

const FAST_DIR := "user://terrain_cache/_fast"
const MAGIC_DEM := 0x314D4544   # "DEM1"
const MAGIC_OSM := 0x314D534F   # "OSM1"
const DEM_HEADER_BYTES := 32    # magic:u32, pad:u32, size:i64, mtime:i64, cols:i32, rows:i32
const OSM_HEADER_BYTES := 20    # magic:u32, size:i64, mtime:i64


static func bin_path_for(json_path: String) -> String:
	var sub := json_path.get_base_dir().get_file()
	var base := json_path.get_file().get_basename()
	return "%s/%s__%s.bin" % [FAST_DIR, sub, base]


static func _source_stat(json_path: String) -> Vector2i:
	if not FileAccess.file_exists(json_path):
		return Vector2i(-1, -1)
	var f := FileAccess.open(json_path, FileAccess.READ)
	if f == null:
		return Vector2i(-1, -1)
	var sz := int(f.get_length())
	f.close()
	var mt := int(FileAccess.get_modified_time(json_path))
	return Vector2i(sz, mt)


## Fast binary read for a cached DEM (`{grid, cols, rows}`), or `{}` on miss.
static func read_dem(json_path: String) -> Dictionary:
	var stat := _source_stat(json_path)
	if stat.x <= 0:
		return {}
	var bp := bin_path_for(json_path)
	if not FileAccess.file_exists(bp):
		return {}
	var f := FileAccess.open(bp, FileAccess.READ)
	if f == null:
		return {}
	var total := int(f.get_length())
	if total < DEM_HEADER_BYTES:
		f.close()
		return {}
	var magic := f.get_32()
	var _pad := f.get_32()
	var src_size := f.get_64()
	var src_mtime := f.get_64()
	var cols := int(f.get_32())
	var rows := int(f.get_32())
	if magic != MAGIC_DEM or src_size != stat.x or src_mtime != stat.y or cols < 2 or rows < 2:
		f.close()
		return {}
	var expected_floats := cols * rows
	var payload_bytes := expected_floats * 4
	if total != DEM_HEADER_BYTES + payload_bytes:
		f.close()
		return {}
	var raw := f.get_buffer(payload_bytes)
	f.close()
	if raw.size() != payload_bytes:
		return {}
	var grid := raw.to_float32_array()
	if grid.size() != expected_floats:
		return {}
	return {"grid": grid, "cols": cols, "rows": rows}


static func write_dem(json_path: String, cols: int, rows: int, grid: PackedFloat32Array) -> void:
	if cols < 2 or rows < 2 or grid.size() != cols * rows:
		return
	var stat := _source_stat(json_path)
	if stat.x <= 0:
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(FAST_DIR))
	var bp := bin_path_for(json_path)
	var f := FileAccess.open(bp, FileAccess.WRITE)
	if f == null:
		return
	f.store_32(MAGIC_DEM)
	f.store_32(0)
	f.store_64(stat.x)
	f.store_64(stat.y)
	f.store_32(cols)
	f.store_32(rows)
	f.store_buffer(grid.to_byte_array())
	f.close()


## Fast binary read for a deserialized OSM payload Dictionary, or `{}` on miss.
static func read_payload(json_path: String) -> Dictionary:
	var stat := _source_stat(json_path)
	if stat.x <= 0:
		return {}
	var bp := bin_path_for(json_path)
	if not FileAccess.file_exists(bp):
		return {}
	var f := FileAccess.open(bp, FileAccess.READ)
	if f == null:
		return {}
	var total := int(f.get_length())
	if total <= OSM_HEADER_BYTES:
		f.close()
		return {}
	var magic := f.get_32()
	var src_size := f.get_64()
	var src_mtime := f.get_64()
	if magic != MAGIC_OSM or src_size != stat.x or src_mtime != stat.y:
		f.close()
		return {}
	var raw := f.get_buffer(total - OSM_HEADER_BYTES)
	f.close()
	var decoded: Variant = bytes_to_var(raw)
	if decoded is Dictionary:
		return decoded as Dictionary
	return {}


static func write_payload(json_path: String, payload: Dictionary) -> void:
	if payload.is_empty():
		return
	var stat := _source_stat(json_path)
	if stat.x <= 0:
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(FAST_DIR))
	var bp := bin_path_for(json_path)
	var f := FileAccess.open(bp, FileAccess.WRITE)
	if f == null:
		return
	f.store_32(MAGIC_OSM)
	f.store_64(stat.x)
	f.store_64(stat.y)
	f.store_buffer(var_to_bytes(payload))
	f.close()


## Remove `_fast/*.bin` sidecars matching a site coordinate token and optional
## subdir prefix ("dem__", "osm_vectors__", "osm_vegetation__").
static func invalidate_token(token: String, sub_prefix: String = "") -> int:
	if token.is_empty():
		return 0
	var da := DirAccess.open(FAST_DIR)
	if da == null:
		return 0
	var removed := 0
	da.list_dir_begin()
	var fn := da.get_next()
	while fn != "":
		if not da.current_is_dir() and fn.ends_with(".bin") \
				and TerrainCacheSettings.filename_has_token(fn, token):
			if sub_prefix.is_empty() or fn.begins_with(sub_prefix):
				var p := "%s/%s" % [FAST_DIR, fn]
				if DirAccess.remove_absolute(ProjectSettings.globalize_path(p)) == OK:
					removed += 1
		fn = da.get_next()
	da.list_dir_end()
	return removed
