extends Node

## ImageryService — fetches satellite imagery for a location as a single draped
## texture for the generated terrain (ROADMAP Pillar 1, the recognizable-place
## requirement).
##
## Source: ESRI World Imagery XYZ tiles (JPEG, which Godot decodes natively — raw
## Sentinel-2 JP2 is intentionally avoided in v1). Tiles covering the bounding box
## are fetched at a zoom chosen from the extent, stitched into one image, then
## cropped to the exact bbox so UV 0..1 aligns with the terrain mesh.
##   https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer
##   Free for use with attribution (see attribution()).
##
## HTTP + cache + deferred-signal pattern mirrors core/weather_service.gd. Stitched
## results cache as PNG under user://terrain_cache/imagery/. Offline / on failure:
## emits a neutral texture so the world still loads.

## `tag` distinguishes concurrent layers for one site, e.g. "base" (the full ~30 km
## drape) vs "detail" (the high-res centre patch). Callers connecting older 2-arg
## handlers still work — Godot drops the extra arg.
signal imagery_ready(key: String, texture: ImageTexture, tag: String)
signal imagery_failed(reason: String, tag: String)
signal imagery_progress(done: int, total: int)

const TILE_URL := "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/%d/%d/%d"
const CACHE_DIR := "user://terrain_cache/imagery"
const CACHE_VERSION := "v1"
const TILE_PX := 256
const ATTRIBUTION := "Imagery © Esri, Maxar, Earthstar Geographics, and the GIS User Community"
## Polite spacing between tiles, and backoff when a tile server throttles us.
const TILE_DELAY := 0.12
const RETRY_BACKOFF := 3.0
const MAX_RETRIES := 4

var _http: HTTPRequest = null
var _busy: bool = false
var _job: Dictionary = {}
## Pending jobs (base + detail layers serialise through the single HTTPRequest).
var _pending: Array[Dictionary] = []


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE_DIR))
	_ensure_http()


func _ensure_http() -> void:
	if _http != null and is_instance_valid(_http):
		return
	_http = HTTPRequest.new()
	_http.timeout = 60.0
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)


func attribution() -> String:
	return ATTRIBUTION


## Fetch (or load from cache) draped imagery for the square of side
## (2*half_extent_m) centred on (lat, lon). Emits imagery_ready when done.
## `tag` labels the layer ("base", "detail", …) and is echoed back in the signals;
## `max_zoom` caps the zoom pick (raise it for a small high-res centre patch).
## Multiple requests serialise through one HTTPRequest, so base + detail can be
## fired together without colliding.
func request_imagery(lat: float, lon: float, half_extent_m: float,
		target_px: int = 2048, tag: String = "base", max_zoom: int = 17) -> void:
	var bbox := GeoMath.bbox_for(lat, lon, half_extent_m)
	var z := GeoMath.pick_zoom(bbox, target_px, max_zoom)
	var key := _cache_key(lat, lon, half_extent_m, z)
	var cache_path := "%s/%s.png" % [CACHE_DIR, key]
	if TerrainCacheSettings.cache_enabled() and FileAccess.file_exists(cache_path):
		var img := Image.new()
		if img.load(cache_path) == OK:
			imagery_ready.emit.call_deferred(key, ImageTexture.create_from_image(img), tag)
			return

	var rng := GeoMath.tile_range_for_bbox(bbox, z)
	var cols := int(rng["max_x"]) - int(rng["min_x"]) + 1
	var rows := int(rng["max_y"]) - int(rng["min_y"]) + 1
	var tiles := []
	for ty in range(int(rng["min_y"]), int(rng["max_y"]) + 1):
		for tx in range(int(rng["min_x"]), int(rng["max_x"]) + 1):
			tiles.append(Vector2i(tx, ty))
	var stitched := Image.create(cols * TILE_PX, rows * TILE_PX, false, Image.FORMAT_RGB8)
	_pending.append({
		"key": key,
		"tag": tag,
		"z": z,
		"bbox": bbox,
		"min_x": int(rng["min_x"]),
		"min_y": int(rng["min_y"]),
		"cols": cols,
		"rows": rows,
		"tiles": tiles,
		"idx": 0,
		"img": stitched,
		"retries": 0,
	})
	_start_next()


## Begin the next queued job if idle.
func _start_next() -> void:
	if _busy or _pending.is_empty():
		return
	_job = _pending.pop_front()
	_busy = true
	_fire_tile()


func _fire_tile() -> void:
	_ensure_http()
	var tiles: Array = _job["tiles"]
	var t: Vector2i = tiles[int(_job["idx"])]
	var url := TILE_URL % [int(_job["z"]), t.y, t.x]
	var err := _http.request(url)
	if err != OK:
		_fail("HTTPRequest error %d" % err)


func _on_request_completed(result: int, response_code: int,
		_headers: PackedStringArray, body: PackedByteArray) -> void:
	if _job.is_empty():
		return
	if result != HTTPRequest.RESULT_SUCCESS:
		_fail("fetch failed (result %d, HTTP %d)" % [result, response_code])
		return
	if response_code == 429 or response_code >= 500:
		var retries := int(_job.get("retries", 0)) + 1
		_job["retries"] = retries
		if retries > MAX_RETRIES:
			_fail("rate limited (HTTP %d) after %d retries" % [response_code, MAX_RETRIES])
			return
		_after(RETRY_BACKOFF * float(retries), _fire_tile)
		return
	if response_code != 200:
		_fail("fetch failed (result %d, HTTP %d)" % [result, response_code])
		return
	var tile_img := Image.new()
	# ESRI World Imagery serves JPEG; fall back to PNG just in case.
	if tile_img.load_jpg_from_buffer(body) != OK and tile_img.load_png_from_buffer(body) != OK:
		_fail("tile decode failed")
		return
	if tile_img.get_format() != Image.FORMAT_RGB8:
		tile_img.convert(Image.FORMAT_RGB8)
	var tiles: Array = _job["tiles"]
	var idx := int(_job["idx"])
	var t: Vector2i = tiles[idx]
	var px := (t.x - int(_job["min_x"])) * TILE_PX
	var py := (t.y - int(_job["min_y"])) * TILE_PX
	var stitched: Image = _job["img"]
	stitched.blit_rect(tile_img, Rect2i(0, 0, TILE_PX, TILE_PX), Vector2i(px, py))

	_job["idx"] = idx + 1
	_job["retries"] = 0
	imagery_progress.emit(idx + 1, tiles.size())
	if idx + 1 < tiles.size():
		_after(TILE_DELAY, _fire_tile)
	else:
		_finish()


func _after(delay: float, cb: Callable) -> void:
	var fire := func() -> void:
		if _busy and not _job.is_empty():
			cb.call()
	get_tree().create_timer(delay).timeout.connect(fire, CONNECT_ONE_SHOT)


func _finish() -> void:
	var stitched: Image = _job["img"]
	var z := int(_job["z"])
	var bbox: Dictionary = _job["bbox"]
	# Crop the tile-aligned mosaic down to the exact bbox so UV 0..1 maps to the
	# same ground area as the terrain mesh.
	var f_nw := GeoMath.lonlat_to_tile_f(bbox["west"], bbox["north"], z)
	var f_se := GeoMath.lonlat_to_tile_f(bbox["east"], bbox["south"], z)
	var x0 := int(round((f_nw.x - float(_job["min_x"])) * TILE_PX))
	var y0 := int(round((f_nw.y - float(_job["min_y"])) * TILE_PX))
	var x1 := int(round((f_se.x - float(_job["min_x"])) * TILE_PX))
	var y1 := int(round((f_se.y - float(_job["min_y"])) * TILE_PX))
	var rw := clampi(x1 - x0, 1, stitched.get_width() - x0)
	var rh := clampi(y1 - y0, 1, stitched.get_height() - y0)
	var region := stitched.get_region(Rect2i(x0, y0, rw, rh))

	var key := str(_job["key"])
	var tag := str(_job.get("tag", "base"))
	if TerrainCacheSettings.cache_enabled():
		region.save_png("%s/%s.png" % [CACHE_DIR, key])
	_busy = false
	_job = {}
	imagery_ready.emit(key, ImageTexture.create_from_image(region), tag)
	_start_next()


func _fail(reason: String) -> void:
	var tag := str(_job.get("tag", "base"))
	_busy = false
	_job = {}
	imagery_failed.emit(reason, tag)
	_start_next()


static func _cache_key(lat: float, lon: float, half_extent_m: float, z: int) -> String:
	return "img_%s_%.4f_%.4f_%d_z%d" % [CACHE_VERSION, lat, lon, int(half_extent_m), z]
