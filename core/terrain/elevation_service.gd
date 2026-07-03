extends Node

## ElevationService — fetches DEM grids for the terrain builder. Supports tagged
## base + detail layers (mirrors ImageryService), job queueing, and best-available
## source selection: Open-Meteo (no key), OpenTopography SRTM 30 m, USGS 10 m DTM.

signal elevation_ready(key: String, grid: PackedFloat32Array, cols: int, rows: int, tag: String)
signal elevation_failed(reason: String, tag: String)
signal elevation_progress(done: int, total: int)

const OPEN_METEO_URL := "https://api.open-meteo.com/v1/elevation"
const OPENTOPO_GLOBAL_URL := "https://portal.opentopography.org/API/globaldem"
const OPENTOPO_USGS_URL := "https://portal.opentopography.org/API/usgsdem"
const CACHE_DIR := "user://terrain_cache/dem"
const CACHE_VERSION := "v2"
const CONFIG_PATH := "user://terrain_config.cfg"

const DEFAULT_GRID_N := 16
const DETAIL_GRID_N := 512
const OPENTOPO_GRID_N := 256
## Cap for the Open-Meteo (no-key) detail fetch: 64² = 4,096 points = ~41 serial
## batch requests (≈20 s) instead of 512² = 262,144 points = ~2,600 requests. The
## upsampled detail mesh/collider hide the difference (Open-Meteo's DEM is ~90 m).
const OPENMETEO_DETAIL_N := 64
const BATCH_SIZE := 100
const POOL_SIZE := 1
const DISPATCH_DELAY := 0.5
const RETRY_BACKOFF := 4.0
const MAX_RETRIES := 3

var _pool: Array[HTTPRequest] = []
var _busy: bool = false
var _job: Dictionary = {}
var _pending: Array[Dictionary] = []
var _opentopo_http: HTTPRequest = null
## Set when Open-Meteo returns a daily quota error — further Open-Meteo fetches
## fail fast and the loader skips the no-key detail storm.
var _openmeteo_daily_exhausted := false


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE_DIR))
	_ensure_pool()


func _ensure_pool() -> void:
	if not _pool.is_empty():
		return
	for i in POOL_SIZE:
		var http := HTTPRequest.new()
		http.timeout = 60.0
		add_child(http)
		http.request_completed.connect(_on_pool_completed.bind(i))
		_pool.append(http)


func has_opentopo_key() -> bool:
	return _opentopo_key() != ""


func is_openmeteo_daily_exhausted() -> bool:
	return _openmeteo_daily_exhausted


## Cancel in-flight HTTP and queued jobs (map switch / new load sequence).
func reset_session() -> void:
	for http in _pool:
		if is_instance_valid(http):
			http.cancel_request()
	if _opentopo_http != null and is_instance_valid(_opentopo_http):
		_opentopo_http.cancel_request()
	_busy = false
	_job = {}
	_pending.clear()


## True when a DEM has real relief (rejects flat 2×2 fallbacks and corrupt caches).
static func grid_is_usable(grid: PackedFloat32Array, cols: int, rows: int) -> bool:
	if grid.is_empty() or cols < 2 or rows < 2 or grid.size() != cols * rows:
		return false
	var lo := INF
	var hi := -INF
	var valid := 0
	for v in grid:
		if is_nan(v):
			continue
		valid += 1
		lo = minf(lo, v)
		hi = maxf(hi, v)
	if valid < 4:
		return false
	if cols == 2 and rows == 2 and hi - lo < 0.01:
		return false
	return hi > lo and (hi - lo) >= 0.5


## Best on-disk DEM for a site (ignores cache_enabled — used when live fetch fails).
static func find_usable_cached_dem(lat: float, lon: float, tag: String = "") -> Dictionary:
	var token := TerrainCacheSettings.coord_token(lat, lon)
	var da := DirAccess.open(CACHE_DIR)
	if da == null:
		return {}
	var best: Dictionary = {}
	var best_range := -1.0
	da.list_dir_begin()
	var fn := da.get_next()
	while fn != "":
		if not da.current_is_dir() and fn.begins_with("dem_") and fn.ends_with(".json") and token in fn:
			if not tag.is_empty():
				var tag_needle := "_%s_" % tag
				if tag_needle not in fn:
					fn = da.get_next()
					continue
			var path := "%s/%s" % [CACHE_DIR, fn]
			var loaded := _load_cache_file(path)
			if loaded.is_empty():
				fn = da.get_next()
				continue
			var grid: PackedFloat32Array = loaded["grid"]
			var cols: int = int(loaded["cols"])
			var rows: int = int(loaded["rows"])
			if not grid_is_usable(grid, cols, rows):
				fn = da.get_next()
				continue
			var lo := INF
			var hi := -INF
			for v in grid:
				if not is_nan(v):
					lo = minf(lo, v)
					hi = maxf(hi, v)
			var span := hi - lo
			if span > best_range:
				best_range = span
				best = loaded
		fn = da.get_next()
	da.list_dir_end()
	return best


## Fetch elevation for square of side (2*half_extent_m). `tag` labels the layer
## ("base", "detail", …). Jobs queue through a single active fetch.
func request_elevation(lat: float, lon: float, half_extent_m: float,
		grid_n: int = DEFAULT_GRID_N, tag: String = "base") -> void:
	var req := {
		"lat": lat,
		"lon": lon,
		"half_extent_m": half_extent_m,
		"grid_n": grid_n,
		"tag": tag,
	}
	_pending.append(req)
	_start_next()


func _start_next() -> void:
	if _busy or _pending.is_empty():
		return
	var req: Dictionary = _pending.pop_front()
	var lat: float = float(req["lat"])
	var lon: float = float(req["lon"])
	var half_extent_m: float = float(req["half_extent_m"])
	var grid_n: int = int(req["grid_n"])
	var tag: String = str(req["tag"])
	var source := _pick_source(lat, lon, tag)
	var effective_n := grid_n
	if source.begins_with("opentopo"):
		effective_n = maxi(grid_n, OPENTOPO_GRID_N if tag == "base" else DETAIL_GRID_N)
	elif tag == "detail" and source == "openmeteo":
		# Open-Meteo is point-query only (BATCH_SIZE per request) and rate-limits
		# CONCURRENT connections hard, so fetches run sequentially. The detail layer
		# asks for DETAIL_GRID_N (512²) which over OpenMeteo would be ~2,600 serial
		# requests — a 20-minute storm that rate-limit-fails and can take the process
		# down ("exits without error" on an uncached load). Open-Meteo's source is
		# only ~90 m Copernicus anyway, so cap the fetched grid at OPENMETEO_DETAIL_N
		# (~47 m spacing over the 3 km patch, still finer than the source); the
		# mesh/collider upsample from it. OpenTopography (key) keeps full resolution
		# via a single AAIGrid request and is unaffected.
		effective_n = mini(grid_n, OPENMETEO_DETAIL_N)
	var key := _cache_key(lat, lon, half_extent_m, effective_n, tag, source)
	var cache_path := "%s/%s.json" % [CACHE_DIR, key]
	if TerrainCacheSettings.cache_enabled() and FileAccess.file_exists(cache_path):
		var cached := _load_cache(cache_path)
		if not cached.is_empty():
			print("ElevationService: '%s' DEM served from cache (%s) — no download" % [tag, key])
			elevation_ready.emit.call_deferred(key,
				cached["grid"], int(cached["cols"]), int(cached["rows"]), tag)
			_start_next()
			return
	if source == "openmeteo" and _openmeteo_daily_exhausted:
		var recovered := find_usable_cached_dem(lat, lon, tag)
		if not recovered.is_empty():
			push_warning("ElevationService: Open-Meteo quota exhausted — using recovered '%s' DEM from disk" % tag)
			elevation_ready.emit.call_deferred(key,
				recovered["grid"], int(recovered["cols"]), int(recovered["rows"]), tag)
			_start_next()
			return
		_fail("Open-Meteo daily elevation quota exceeded — add OpenTopography key or try tomorrow")
		return
	print("ElevationService: '%s' DEM not cached — fetching via %s (grid %d²) …" % [tag, source, effective_n])
	match source:
		"openmeteo":
			_request_open_meteo(lat, lon, half_extent_m, effective_n, key, tag)
		"opentopo_usgs10":
			_request_opentopo(lat, lon, half_extent_m, effective_n, key, tag,
				"USGS10m", OPENTOPO_USGS_URL)
		_:
			_request_opentopo(lat, lon, half_extent_m, effective_n, key, tag,
				"SRTMGL1", OPENTOPO_GLOBAL_URL)


static func _pick_source(lat: float, lon: float, tag: String) -> String:
	var api_key := ""
	if FileAccess.file_exists(CONFIG_PATH):
		var cfg := ConfigFile.new()
		if cfg.load(CONFIG_PATH) == OK:
			api_key = str(cfg.get_value("opentopography", "api_key", ""))
	if api_key != "":
		if tag == "detail" and _is_us_site(lat, lon):
			return "opentopo_usgs10"
		return "opentopo_global"
	if tag == "detail":
		return "openmeteo"
	return "openmeteo"


static func _is_us_site(lat: float, lon: float) -> bool:
	return lat >= 24.0 and lat <= 50.0 and lon >= -125.0 and lon <= -66.0


func _request_open_meteo(lat: float, lon: float, half_extent_m: float,
		grid_n: int, key: String, tag: String) -> void:
	var bbox := GeoMath.bbox_for(lat, lon, half_extent_m)
	var lats := PackedFloat32Array()
	var lons := PackedFloat32Array()
	var inv := 1.0 / float(maxi(grid_n - 1, 1))
	for r in grid_n:
		var la := lerpf(bbox["north"], bbox["south"], float(r) * inv)
		for c in grid_n:
			var lo := lerpf(bbox["west"], bbox["east"], float(c) * inv)
			lats.append(la)
			lons.append(lo)
	var total_batches := int(ceil(float(lats.size()) / float(BATCH_SIZE)))
	var queue: Array = []
	for b in total_batches:
		queue.append(b)
	var results: Array = []
	results.resize(total_batches)
	var worker_batch: Array = []
	worker_batch.resize(POOL_SIZE)
	worker_batch.fill(-1)
	_job = {
		"source": "openmeteo",
		"key": key,
		"tag": tag,
		"cols": grid_n,
		"rows": grid_n,
		"lats": lats,
		"lons": lons,
		"queue": queue,
		"results": results,
		"remaining": total_batches,
		"total_batches": total_batches,
		"retries": {},
		"worker_batch": worker_batch,
	}
	_busy = true
	_ensure_pool()
	for w in POOL_SIZE:
		_dispatch_next(w)


func _dispatch_next(worker: int) -> void:
	if _job.is_empty() or str(_job.get("source", "")) != "openmeteo":
		return
	var queue: Array = _job["queue"]
	if queue.is_empty():
		_job["worker_batch"][worker] = -1
		return
	var batch: int = queue.pop_front()
	_job["worker_batch"][worker] = batch
	var lats: PackedFloat32Array = _job["lats"]
	var lons: PackedFloat32Array = _job["lons"]
	var start := batch * BATCH_SIZE
	var end := mini(start + BATCH_SIZE, lats.size())
	var lat_parts := PackedStringArray()
	var lon_parts := PackedStringArray()
	for i in range(start, end):
		lat_parts.append("%.5f" % lats[i])
		lon_parts.append("%.5f" % lons[i])
	var url := "%s?latitude=%s&longitude=%s" % [
		OPEN_METEO_URL, ",".join(lat_parts), ",".join(lon_parts)]
	var err := _pool[worker].request(url)
	if err != OK:
		_fail("HTTPRequest error %d" % err)


func _on_pool_completed(result: int, response_code: int,
		_headers: PackedStringArray, body: PackedByteArray, worker: int) -> void:
	if _job.is_empty() or str(_job.get("source", "")) != "openmeteo":
		return
	var batch: int = _job["worker_batch"][worker]
	if batch < 0:
		return
	if result != HTTPRequest.RESULT_SUCCESS:
		_fail("fetch failed (result %d, HTTP %d)" % [result, response_code])
		return
	var body_text := body.get_string_from_utf8()
	if response_code == 429 or response_code >= 500:
		if _is_openmeteo_daily_limit(response_code, body_text):
			_openmeteo_daily_exhausted = true
			_fail("Open-Meteo daily elevation quota exceeded — add OpenTopography key or try tomorrow")
			return
		var retries: Dictionary = _job["retries"]
		var n := int(retries.get(batch, 0)) + 1
		retries[batch] = n
		if n > MAX_RETRIES:
			_fail("rate limited (HTTP %d) after %d retries" % [response_code, MAX_RETRIES])
			return
		_after(RETRY_BACKOFF * float(n), func() -> void:
			if _job.is_empty():
				return
			(_job["queue"] as Array).push_back(batch)
			_dispatch_next(worker))
		return
	if response_code != 200:
		_fail("fetch failed (result %d, HTTP %d)" % [result, response_code])
		return
	var parsed: Variant = JSON.parse_string(body_text)
	if parsed is Dictionary and bool((parsed as Dictionary).get("error", false)):
		var reason := str((parsed as Dictionary).get("reason", "Open-Meteo error"))
		if _is_openmeteo_daily_limit(response_code, body_text):
			_openmeteo_daily_exhausted = true
			_fail("Open-Meteo daily elevation quota exceeded — add OpenTopography key or try tomorrow")
		else:
			_fail(reason)
		return
	if not (parsed is Dictionary) or not (parsed as Dictionary).has("elevation"):
		_fail("unparseable elevation response")
		return
	var arr := PackedFloat32Array()
	for v in ((parsed as Dictionary)["elevation"] as Array):
		arr.append(TerrainBuilder.variant_to_float(v, NAN) if v != null else NAN)
	_job["results"][batch] = arr
	_job["remaining"] = int(_job["remaining"]) - 1
	elevation_progress.emit(int(_job["total_batches"]) - int(_job["remaining"]),
		int(_job["total_batches"]))
	if int(_job["remaining"]) <= 0:
		_finish_open_meteo()
	else:
		_after(DISPATCH_DELAY, func() -> void: _dispatch_next(worker))


func _finish_open_meteo() -> void:
	var cols := int(_job["cols"])
	var rows := int(_job["rows"])
	var key := str(_job["key"])
	var tag := str(_job.get("tag", "base"))
	var grid := PackedFloat32Array()
	for part in (_job["results"] as Array):
		if part == null:
			_fail("missing batch in assembly")
			return
		grid.append_array(part as PackedFloat32Array)
	if grid.size() != cols * rows:
		_fail("grid size mismatch (%d != %d)" % [grid.size(), cols * rows])
		return
	if not grid_is_usable(grid, cols, rows):
		_fail("elevation grid has no usable relief")
		return
	_save_cache(key, grid, cols, rows)
	_busy = false
	_job = {}
	elevation_ready.emit(key, grid, cols, rows, tag)
	_start_next()


func _request_opentopo(lat: float, lon: float, half_extent_m: float,
		grid_n: int, key: String, tag: String, dem_name: String, base_url: String) -> void:
	var bbox := GeoMath.bbox_for(lat, lon, half_extent_m)
	var api_key := _opentopo_key()
	var url := ""
	if base_url == OPENTOPO_USGS_URL:
		url = "%s?datasetName=%s&south=%.6f&north=%.6f&west=%.6f&east=%.6f&outputFormat=AAIGrid&API_Key=%s" % [
			base_url, dem_name, bbox["south"], bbox["north"], bbox["west"], bbox["east"], api_key]
	else:
		url = "%s?demtype=%s&south=%.6f&north=%.6f&west=%.6f&east=%.6f&outputFormat=AAIGrid&API_Key=%s" % [
			base_url, dem_name, bbox["south"], bbox["north"], bbox["west"], bbox["east"], api_key]
	_job = {
		"source": "opentopo",
		"key": key,
		"tag": tag,
		"target_n": grid_n,
		"url": url,
		"retries": 0,
	}
	_busy = true
	_ensure_opentopo_http()
	var err := _opentopo_http.request(url)
	if err != OK:
		_fail("HTTPRequest error %d" % err)


func _ensure_opentopo_http() -> void:
	if _opentopo_http != null and is_instance_valid(_opentopo_http):
		return
	_opentopo_http = HTTPRequest.new()
	_opentopo_http.timeout = 90.0
	add_child(_opentopo_http)
	_opentopo_http.request_completed.connect(_on_opentopo_completed)


func _on_opentopo_completed(result: int, response_code: int,
		_headers: PackedStringArray, body: PackedByteArray) -> void:
	if _job.is_empty() or str(_job.get("source", "")) != "opentopo":
		return
	if result != HTTPRequest.RESULT_SUCCESS:
		_fail("fetch failed (result %d, HTTP %d)" % [result, response_code])
		return
	if response_code == 429 or response_code >= 500:
		var n := int(_job.get("retries", 0)) + 1
		_job["retries"] = n
		if n > MAX_RETRIES:
			_fail("rate limited (HTTP %d) after %d retries" % [response_code, MAX_RETRIES])
			return
		_after(RETRY_BACKOFF * float(n), func() -> void:
			if not _job.is_empty():
				_opentopo_http.request(str(_job.get("url", ""))))
		return
	if response_code != 200:
		_fail("fetch failed (result %d, HTTP %d)" % [result, response_code])
		return
	var target_n := int(_job.get("target_n", DEFAULT_GRID_N))
	var key := str(_job.get("key", ""))
	var tag := str(_job.get("tag", "base"))
	var parsed := parse_aaigrid(body.get_string_from_utf8())
	if parsed.is_empty():
		_fail("opentopo parse failed")
		return
	var src: PackedFloat32Array = parsed["grid"]
	var grid := TerrainBuilder.resample(src, int(parsed["cols"]), int(parsed["rows"]), target_n)
	_save_cache(key, grid, target_n, target_n)
	_busy = false
	_job = {}
	elevation_ready.emit(key, grid, target_n, target_n, tag)
	_start_next()


static func parse_aaigrid(text: String) -> Dictionary:
	var cols := 0
	var rows := 0
	var nodata := -9999.0
	var values := PackedFloat32Array()
	var in_data := false
	for raw_line in text.split("\n", false):
		var line := raw_line.strip_edges()
		if line.is_empty():
			continue
		var low := line.to_lower()
		if not in_data and (low.begins_with("ncols") or low.begins_with("nrows") \
				or low.begins_with("xllcorner") or low.begins_with("yllcorner") \
				or low.begins_with("xllcenter") or low.begins_with("yllcenter") \
				or low.begins_with("cellsize") or low.begins_with("nodata")):
			var parts := line.split(" ", false)
			if parts.size() >= 2:
				if low.begins_with("ncols"):
					cols = int(parts[1])
				elif low.begins_with("nrows"):
					rows = int(parts[1])
				elif low.begins_with("nodata"):
					nodata = TerrainBuilder.variant_to_float(parts[1], -9999.0)
			continue
		in_data = true
		for tok in line.split(" ", false):
			if tok.is_empty():
				continue
			var v := TerrainBuilder.variant_to_float(tok, nodata)
			values.append(NAN if is_equal_approx(v, nodata) else v)
	if cols <= 0 or rows <= 0 or values.size() != cols * rows:
		return {}
	return {"cols": cols, "rows": rows, "grid": values}


func _after(delay: float, cb: Callable) -> void:
	var fire := func() -> void:
		if _busy and not _job.is_empty():
			cb.call()
	get_tree().create_timer(delay).timeout.connect(fire, CONNECT_ONE_SHOT)


func _fail(reason: String) -> void:
	var tag := str(_job.get("tag", "base"))
	_busy = false
	_job = {}
	elevation_failed.emit(reason, tag)
	_start_next()


static func _cache_key(lat: float, lon: float, half_extent_m: float,
		grid_n: int, tag: String, source: String) -> String:
	return "dem_%s_%s_%s_%.4f_%.4f_%d_%d" % [
		CACHE_VERSION, tag, source, lat, lon, int(half_extent_m), grid_n]


func _save_cache(key: String, grid: PackedFloat32Array, cols: int, rows: int) -> void:
	if not TerrainCacheSettings.cache_enabled():
		return
	var f := FileAccess.open("%s/%s.json" % [CACHE_DIR, key], FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"cols": cols, "rows": rows, "grid": Array(grid)}))
	f.close()


func _load_cache(path: String) -> Dictionary:
	return _load_cache_file(path)


static func _load_cache_file(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary):
		return {}
	var d: Dictionary = parsed
	var cols := int(d.get("cols", 0))
	var rows := int(d.get("rows", 0))
	var grid := PackedFloat32Array()
	for v in (d.get("grid", []) as Array):
		grid.append(TerrainBuilder.variant_to_float(v, NAN))
	if grid.is_empty():
		return {}
	if not grid_is_usable(grid, cols, rows):
		push_warning("ElevationService: rejecting unusable cached DEM %s" % path)
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		return {}
	return {"grid": grid, "cols": cols, "rows": rows}


static func _is_openmeteo_daily_limit(response_code: int, body_text: String) -> bool:
	if body_text.is_empty():
		return false
	if body_text.to_lower().contains("daily api request limit"):
		return true
	var parsed: Variant = JSON.parse_string(body_text)
	if parsed is Dictionary:
		var reason := str((parsed as Dictionary).get("reason", "")).to_lower()
		if "daily" in reason and "limit" in reason:
			return true
		if bool((parsed as Dictionary).get("error", false)) and response_code == 429:
			return "limit" in reason
	return false


func _opentopo_key() -> String:
	if not FileAccess.file_exists(CONFIG_PATH):
		return ""
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		return ""
	return str(cfg.get_value("opentopography", "api_key", ""))
