extends Node

## ElevationService — fetches DEM grids for the terrain builder. Supports tagged
## base + detail layers (mirrors ImageryService), job queueing, and best-available
## source selection: Open-Meteo (no key), OpenTopography SRTM 30 m, USGS 10 m DTM,
## and USGS 3DEP 1 m lidar for the near-field detail patch over US sites.
##
## CRS warning: the 3DEP 1 m AAIGrid arrives in UTM METRES; every other source
## here is in degrees. resample_aaigrid_to_bbox dispatches on that — see
## aaigrid_is_projected.

signal elevation_ready(key: String, grid: PackedFloat32Array, cols: int, rows: int, tag: String)
signal elevation_failed(reason: String, tag: String)
signal elevation_progress(done: int, total: int)

const OPEN_METEO_URL := "https://api.open-meteo.com/v1/elevation"
const OPENTOPO_GLOBAL_URL := "https://portal.opentopography.org/API/globaldem"
const OPENTOPO_USGS_URL := "https://portal.opentopography.org/API/usgsdem"
const CACHE_DIR := "user://terrain_cache/dem"
## v4: OpenTopo AAIGrid is georeferenced into the requested bbox (v3 stretched
## cell-snapped grids onto the mesh and shifted relief vs OSM/imagery).
const CACHE_VERSION := "v4"
const CONFIG_PATH := "user://terrain_config.cfg"

const DEFAULT_GRID_N := 64
const DEFAULT_GRID_N_LEGACY := 16
const DETAIL_GRID_N := 512
const OPENTOPO_GRID_N := 256
## Cap for the Open-Meteo (no-key) detail fetch: 64² = 4,096 points = ~41 serial
## batch requests (≈20 s) instead of 512² = 262,144 points = ~2,600 requests. The
## upsampled detail mesh/collider hide the difference (Open-Meteo's DEM is ~90 m).
const OPENMETEO_DETAIL_N := 64
## USGS 3DEP 1 m lidar DEM, via OpenTopography's `usgsdem` endpoint. AAIGrid runs
## ~21 bytes per cell, so a 3 km detail square is ~9 M cells ≈ 190 MB of ASCII
## (~15 s to pull, ~7 s to parse, measured). That is fine once per site because
## it caches, but it does not scale — anything wider drops to USGS10m.
##
## Being under this size is NECESSARY but not SUFFICIENT: OpenTopography also
## gates the whole USGS1m dataset to academic-verified accounts — a plain
## self-registered key gets HTTP 401 "restricted for academics" at every site,
## coverage notwithstanding (confirmed empirically; see
## https://opentopography.org/content/how-access-restricted-data-opentopography
## for the request process, or email info@opentopography.org re: an Enterprise
## key). That 401 is classified `permanent` in _advance_ladder same as a
## genuine coverage gap — both correctly fall back to USGS10m — but the two
## causes are NOT the same story for a player, so the real reason is recorded
## (usgs1m_miss_reason) rather than collapsed into one generic message.
const USGS1M_MAX_SIDE_M := 3200.0
const BATCH_SIZE := 100
const POOL_SIZE := 1
const DISPATCH_DELAY := 0.5
const RETRY_BACKOFF := 4.0
const MAX_RETRIES := 3
## Open-Meteo grid cap for a base DEM (96² = 93 serial batches). Also the size
## a keyed base request falls back to when every OpenTopography product failed.
const OPENMETEO_BASE_MAX_N := 96
## Largest single OpenTopography AAIGrid we ask for, in source cells; bigger
## global squares go up as tiles (tile_bboxes). ~2 M cells ≈ 16 MB of ASCII.
## Measured 2026-10-19: one 3.5 M-cell COP90 square (160 km) loaded, one of
## ~5 M (180 km) did not; at 1.2 M a 180 km world took 9 calls / 194 s, the
## time going on per-request latency, so tiles stay few and large.
const OPENTOPO_MAX_TILE_CELLS := 2000000.0

var _pool: Array[HTTPRequest] = []
var _busy: bool = false
var _job: Dictionary = {}
var _pending: Array[Dictionary] = []
var _opentopo_http: HTTPRequest = null
## Set when Open-Meteo returns a daily quota error — further Open-Meteo fetches
## fail fast and the loader skips the no-key detail storm.
var _openmeteo_daily_exhausted := false
## Bumped per job and per reset_session: a retry timer only acts while the job
## it was armed for is still the current one (a stale timer used to re-send
## the NEW job's request on a busy HTTPRequest and fail it).
var _job_seq := 0


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE_DIR))
	_ensure_pool()


## Base DEM grid N from terrain_config.cfg (default 64²).
static func base_grid_n() -> int:
	var n := DEFAULT_GRID_N
	if FileAccess.file_exists(CONFIG_PATH):
		var cfg := ConfigFile.new()
		if cfg.load(CONFIG_PATH) == OK:
			n = int(cfg.get_value("terrain", "base_dem_grid_n", DEFAULT_GRID_N))
	return maxi(n, 8)


## Scale base DEM density with world radius so distant peaks stay on the mesh.
## Open-Meteo (no key) caps lower to avoid multi-thousand serial point queries.
static func base_grid_n_for_extent(half_extent_m: float) -> int:
	var cfg_n := base_grid_n()
	var extent_m := half_extent_m * 2.0
	var target_spacing_m := 700.0
	var needed := int(ceil(extent_m / target_spacing_m)) + 1
	needed = clampi(maxi(needed, cfg_n), 8, 256)
	if not _static_has_opentopo_key():
		needed = mini(needed, OPENMETEO_BASE_MAX_N)
	return needed


static func _static_has_opentopo_key() -> bool:
	return not _sanitize_api_key(_read_config_api_key()).is_empty()


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
	_job_seq += 1
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
## Prefer an exact `preferred_half_extent_m` match (from the cache filename); never
## return a DEM whose half-extent differs by more than 5% — stretching a wrong
## span onto the mesh shifts OSM buildings/camps relative to the drape.
static func find_usable_cached_dem(lat: float, lon: float, tag: String = "",
		preferred_half_extent_m: float = 0.0) -> Dictionary:
	var token := TerrainCacheSettings.coord_token(lat, lon)
	var da := DirAccess.open(CACHE_DIR)
	if da == null:
		return {}
	var best_exact: Dictionary = {}
	var best_exact_range := -1.0
	var best_any: Dictionary = {}
	var best_any_range := -1.0
	da.list_dir_begin()
	var fn := da.get_next()
	while fn != "":
		if not da.current_is_dir() and fn.begins_with("dem_") and fn.ends_with(".json") and token in fn:
			if not tag.is_empty():
				var tag_needle := "_%s_" % tag
				if tag_needle not in fn:
					fn = da.get_next()
					continue
			var file_half := _half_extent_from_dem_filename(fn)
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
			loaded["half_extent_m"] = file_half
			if preferred_half_extent_m > 0.0 and file_half > 0.0:
				var rel := absf(file_half - preferred_half_extent_m) / preferred_half_extent_m
				if rel <= 0.05 and span > best_exact_range:
					best_exact_range = span
					best_exact = loaded
			if span > best_any_range:
				best_any_range = span
				best_any = loaded
		fn = da.get_next()
	da.list_dir_end()
	if not best_exact.is_empty():
		return best_exact
	# No safe match for the requested span — refuse a mismatched DEM (caller
	# falls back to flat / refetch) rather than stretch the wrong footprint.
	if preferred_half_extent_m > 0.0:
		return {}
	return best_any


## Filename: dem_<ver>_<tag>_<source>_<lat>_<lon>_<half>_<grid>.json
static func _half_extent_from_dem_filename(fn: String) -> float:
	var base := fn.get_basename()
	var parts := base.split("_")
	if parts.size() < 2:
		return 0.0
	return float(parts[parts.size() - 2])


## `<source>` itself may hold 1 or 2 underscore-joined tokens ("openmeteo" vs
## "opentopo_usgs10"), so it can't be read at a fixed index — pull it as
## everything between the fixed 3-token prefix (dem/version/tag) and the fixed
## 4-token suffix (lat/lon/half/grid), the same filename layout
## _half_extent_from_dem_filename already trusts.
static func _source_from_dem_filename(fn: String) -> String:
	var parts := fn.get_basename().split("_")
	if parts.size() < 8:
		return ""
	return "_".join(parts.slice(3, parts.size() - 4))


## Cheap (filename-only, no file content read) lookup of which DEM source is
## actually cached on disk for this site/tag/half-extent right now — for
## surfacing "1 m lidar" vs "10 m USGS" etc. in the UI without decoding a
## potentially 100+ MB JSON grid just to answer that question. Matches the
## half-extent within 5% (mirrors find_usable_cached_dem's tolerance); returns
## "" if nothing on disk matches.
static func cached_dem_source(lat: float, lon: float, tag: String,
		half_extent_m: float) -> String:
	var token := TerrainCacheSettings.coord_token(lat, lon)
	var da := DirAccess.open(CACHE_DIR)
	if da == null:
		return ""
	var tag_needle := "_%s_" % tag
	var best_source := ""
	var best_rel := INF
	da.list_dir_begin()
	var fn := da.get_next()
	while fn != "":
		if not da.current_is_dir() and fn.begins_with("dem_") and fn.ends_with(".json") \
				and token in fn and tag_needle in fn:
			var file_half := _half_extent_from_dem_filename(fn)
			if file_half > 0.0 and half_extent_m > 0.0:
				var rel := absf(file_half - half_extent_m) / half_extent_m
				if rel <= 0.05 and rel < best_rel:
					best_rel = rel
					best_source = _source_from_dem_filename(fn)
		fn = da.get_next()
	da.list_dir_end()
	return best_source


## Fetch elevation for square of side (2*half_extent_m). `tag` labels the layer
## ("base", "detail", …). Jobs queue through a single active fetch.
## Pass `force_refetch` to bypass disk cache (refresh without deleting backups).
func request_elevation(lat: float, lon: float, half_extent_m: float,
		grid_n: int = DEFAULT_GRID_N, tag: String = "base", force_refetch: bool = false) -> void:
	var req := {
		"lat": lat,
		"lon": lon,
		"half_extent_m": half_extent_m,
		"grid_n": grid_n,
		"tag": tag,
		"force_refetch": force_refetch,
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
	var force_refetch: bool = bool(req.get("force_refetch", false))
	var ladder := source_ladder(lat, lon, tag, half_extent_m, has_opentopo_key(),
		_usgs1m_known_missing(lat, lon))
	var first: Dictionary = ladder[0]
	var effective_n := rung_grid_n(first, grid_n, tag)
	var key := _cache_key(lat, lon, half_extent_m, effective_n, tag, str(first["cache_source"]))
	var cache_path := "%s/%s.json" % [CACHE_DIR, key]
	var use_cache := not force_refetch and TerrainCacheSettings.cache_enabled()
	if use_cache:
		var cached := _load_cache(cache_path)
		if cached.is_empty():
			# Prefer a prior CACHE_VERSION file over a multi-minute OpenTopo refetch.
			var legacy_path := _legacy_dem_cache_path(cache_path)
			if not legacy_path.is_empty():
				cached = _load_cache(legacy_path)
				if not cached.is_empty():
					print("ElevationService: '%s' DEM served from legacy cache (%s) — promoting" % [
						tag, legacy_path.get_file()])
					_save_cache(key, cached["grid"], int(cached["cols"]), int(cached["rows"]))
		if cached.is_empty() and str(first["kind"]) == "openmeteo":
			# No key on this machine, but a DEM of the same footprint from a
			# BETTER source is on disk (an asset pack from someone with an
			# OpenTopography key, or a key that has since been removed): use
			# it rather than refetch a coarser grid — the world then looks the
			# same as it did for whoever built it.
			var better := find_usable_cached_dem(lat, lon, tag, half_extent_m)
			if not better.is_empty():
				print("ElevationService: '%s' DEM served from another source's cache — no download" % tag)
				_save_cache(key, better["grid"], int(better["cols"]), int(better["rows"]))
				cached = better
		if cached.is_empty():
			# A grid of this square that a LATER rung of the same ladder fetched
			# on an earlier load (the first choice 502'd or timed out then). It
			# used to be cached under the fallback's key and never looked for,
			# so every load retried the failing source and then downloaded the
			# fallback again. Not for a first-choice 1 m request: a transient 1 m
			# failure must not latch the site to 10 m (see _usgs1m_miss_path).
			var alt := _cached_fallback_path(lat, lon, tag, half_extent_m, grid_n, ladder)
			if not alt.is_empty():
				cached = _load_cache(alt)
				if not cached.is_empty():
					print("ElevationService: '%s' DEM served from cache (%s, an earlier fallback) — no download" % [
						tag, alt.get_file().get_basename()])
		if not cached.is_empty():
			print("ElevationService: '%s' DEM served from cache (%s) — no download" % [tag, key])
			elevation_ready.emit.call_deferred(key,
				cached["grid"], int(cached["cols"]), int(cached["rows"]), tag)
			_start_next()
			return
	if str(first["kind"]) == "openmeteo" and _openmeteo_daily_exhausted:
		var recovered := find_usable_cached_dem(lat, lon, tag, half_extent_m)
		if not recovered.is_empty():
			push_warning("ElevationService: Open-Meteo quota exhausted — using recovered '%s' DEM from disk" % tag)
			elevation_ready.emit.call_deferred(key,
				recovered["grid"], int(recovered["cols"]), int(recovered["rows"]), tag)
			_start_next()
			return
		_job = {"tag": tag}
		_fail("Open-Meteo daily elevation quota exceeded — add OpenTopography key or try tomorrow")
		return
	_begin_rung({
		"lat": lat, "lon": lon, "half_extent_m": half_extent_m, "grid_n": grid_n,
		"tag": tag, "ladder": ladder, "rung": 0, "use_cache": use_cache,
	})


## Start (or continue a fallback chain at) one rung of a request's ladder.
## `req` carries lat/lon/half_extent_m/grid_n/tag/ladder/rung/use_cache.
func _begin_rung(req: Dictionary) -> void:
	var ladder: Array = req["ladder"]
	var rung: Dictionary = ladder[int(req["rung"])]
	var lat := float(req["lat"])
	var lon := float(req["lon"])
	var half_extent_m := float(req["half_extent_m"])
	var tag := str(req["tag"])
	var n := rung_grid_n(rung, int(req["grid_n"]), tag)
	var key := _cache_key(lat, lon, half_extent_m, n, tag, str(rung["cache_source"]))
	if int(req["rung"]) > 0 and bool(req.get("use_cache", true)):
		var cached := _load_cache("%s/%s.json" % [CACHE_DIR, key])
		if not cached.is_empty():
			print("ElevationService: '%s' fallback %s served from cache — no download" % [
				tag, str(rung["cache_source"])])
			_busy = false
			_job = {}
			elevation_ready.emit.call_deferred(key,
				cached["grid"], int(cached["cols"]), int(cached["rows"]), tag)
			_start_next()
			return
	if str(rung["kind"]) == "openmeteo":
		if _openmeteo_daily_exhausted:
			_job = {"tag": tag}
			_fail("Open-Meteo daily elevation quota exceeded — add OpenTopography key or try tomorrow")
			return
		print("ElevationService: '%s' DEM not cached — fetching via openmeteo (grid %d²) …" % [tag, n])
		_request_open_meteo(lat, lon, half_extent_m, n, key, tag, req)
		return
	print("ElevationService: '%s' DEM not cached — fetching via %s (grid %d²) …" % [
		tag, str(rung["cache_source"]), n])
	_request_opentopo(lat, lon, half_extent_m, n, key, tag,
		str(rung["dem"]), str(rung["base_url"]), req)


## The DEM sources to try for one request, best first. The last rung is always
## Open-Meteo (no key, ~90 m): with an OpenTopography key that is the safety
## net — a 502 / timeout on every OpenTopography product used to leave the
## world FLAT. Pure (the key and the 1 m miss flag are arguments) so the
## selftest pins it.
static func source_ladder(lat: float, lon: float, tag: String, half_extent_m: float,
		has_key: bool, usgs1m_missing: bool) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if has_key:
		if tag == "base":
			var all: Array[String] = ["SRTMGL1", "SRTMGL3", "COP90"]
			var start := all.find(opentopo_global_demtype(half_extent_m, tag))
			for i in range(maxi(start, 0), all.size()):
				out.append(_opentopo_rung(OPENTOPO_GLOBAL_URL, all[i]))
		else:
			if _is_us_site(lat, lon):
				# 3DEP 1 m lidar where a project flew it and the square is small
				# enough to fetch as ASCII; coverage gaps and academic-only keys
				# drop to 10 m NED.
				if half_extent_m > 0.0 and half_extent_m * 2.0 <= USGS1M_MAX_SIDE_M \
						and not usgs1m_missing:
					out.append(_opentopo_rung(OPENTOPO_USGS_URL, "USGS1m"))
				out.append(_opentopo_rung(OPENTOPO_USGS_URL, "USGS10m"))
			out.append(_opentopo_rung(OPENTOPO_GLOBAL_URL, "SRTMGL1"))
			out.append(_opentopo_rung(OPENTOPO_GLOBAL_URL, "COP90"))
	out.append({"kind": "openmeteo", "cache_source": "openmeteo", "dem": "", "base_url": OPEN_METEO_URL})
	return out


static func _opentopo_rung(base_url: String, dem_name: String) -> Dictionary:
	return {"kind": "opentopo", "base_url": base_url, "dem": dem_name,
		"cache_source": _opentopo_cache_source(base_url, dem_name)}


## Grid N a rung is fetched and cached at (part of its cache key).
static func rung_grid_n(rung: Dictionary, grid_n: int, tag: String) -> int:
	if str(rung.get("kind", "")) == "opentopo":
		return maxi(grid_n, OPENTOPO_GRID_N if tag == "base" else DETAIL_GRID_N)
	if tag == "detail":
		return mini(grid_n, OPENMETEO_DETAIL_N)
	# Open-Meteo as a FALLBACK for a keyed base request: grid_n may be up to
	# 256² = 656 serial batches. 96² (93 batches) is the no-key cap already.
	return mini(grid_n, OPENMETEO_BASE_MAX_N)


## The cache file a later OpenTopography rung of `ladder` left for this square,
## or "". Filename-only scan; never offers Open-Meteo to a keyed request (that
## would block the upgrade a key exists for) or anything to a 1 m first choice.
func _cached_fallback_path(lat: float, lon: float, tag: String, half_extent_m: float,
		grid_n: int, ladder: Array) -> String:
	if ladder.size() < 2 or str((ladder[0] as Dictionary).get("dem", "")) == "USGS1m":
		return ""
	for i in range(1, ladder.size()):
		var rung: Dictionary = ladder[i]
		if str(rung["kind"]) != "opentopo":
			continue
		var key := _cache_key(lat, lon, half_extent_m, rung_grid_n(rung, grid_n, tag), tag,
			str(rung["cache_source"]))
		var path := "%s/%s.json" % [CACHE_DIR, key]
		if FileAccess.file_exists(path):
			return path
	return ""


## Coarser global DEM for large base bboxes — SRTM GL1 at native 30 m over a
## 100 km square is ~3300² AAIGrid cells and routinely times out in Godot.
static func opentopo_global_demtype(half_extent_m: float, tag: String) -> String:
	if tag != "base":
		return "SRTMGL1"
	var side_m := half_extent_m * 2.0
	if side_m > 60000.0:
		return "COP90"
	if side_m > 20000.0:
		return "SRTMGL3"
	return "SRTMGL1"


## terrain_config.cfg wins when set; the OPENTOPOGRAPHY_API_KEY env var is the
## fallback — same precedence AiImageryService already uses for GEMINI_API_KEY,
## kept consistent rather than each key inventing its own order. An alternative
## to hand-editing the gitignored user:// config file (handy for CI, a shared
## machine, or anyone who prefers not to have the key sitting in a plaintext
## file at all). Both are equally safe against an accidental commit: the config
## file lives under user://, which Godot resolves OUTSIDE this repo entirely
## (not merely gitignored — there is no path by which `git add` could ever
## reach it), and an env var never touches disk in the project directory.
static func _read_config_api_key() -> String:
	if FileAccess.file_exists(CONFIG_PATH):
		var cfg := ConfigFile.new()
		if cfg.load(CONFIG_PATH) == OK:
			var k := str(cfg.get_value("opentopography", "api_key", ""))
			if not k.is_empty():
				return k
	return OS.get_environment("OPENTOPOGRAPHY_API_KEY")


static func _sanitize_api_key(raw: String) -> String:
	return raw.strip_edges().replace("\n", "").replace("\r", "")


static func _is_us_site(lat: float, lon: float) -> bool:
	return lat >= 24.0 and lat <= 50.0 and lon >= -125.0 and lon <= -66.0


## Negative-cache marker for "3DEP 1 m does not cover this site". Without it a
## site outside any lidar project re-attempts the ~190 MB 1 m fetch on EVERY
## load before failing over, because the successful 10 m grid caches under a
## different source key than the one the 1 m lookup checks.
##
## The `dem_` prefix and the standard 4-decimal coord token are load-bearing:
## together they are what makes this file sweep away with
## TerrainCacheSettings.invalidate_dem (and the Terrain-options refresh), so a
## recorded miss can never outlive the cache generation it belongs to. Only
## PERMANENT failures write it — see _advance_ladder.
static func _usgs1m_miss_path(lat: float, lon: float) -> String:
	return "%s/dem_usgs1m_miss_%s.flag" % [
		CACHE_DIR, TerrainCacheSettings.coord_token(lat, lon)]


static func _usgs1m_known_missing(lat: float, lon: float) -> bool:
	return FileAccess.file_exists(_usgs1m_miss_path(lat, lon))


## The recorded reason a 1 m fetch was rejected, e.g. "HTTP 401: ... restricted
## for academics ..." — OpenTopography's most common real-world case, not a
## coverage gap (see usgs1m_status()). Empty string if no miss is on file.
static func usgs1m_miss_reason(lat: float, lon: float) -> String:
	var path := _usgs1m_miss_path(lat, lon)
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_file_as_string(path).strip_edges()


static func _mark_usgs1m_missing(lat: float, lon: float, reason: String = "") -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE_DIR))
	var f := FileAccess.open(_usgs1m_miss_path(lat, lon), FileAccess.WRITE)
	if f == null:
		return
	# No "1 m rejected at lat,lon" framing here — the filename already carries
	# the site, and usgs1m_miss_reason()'s callers (the terrain-options UI) add
	# their own framing around this string; doubling both reads as noise.
	f.store_string(reason if not reason.is_empty() else "unknown reason")
	f.close()


## Cache-source label for an OpenTopography product — part of its cache key
## and the source label cached_dem_source() reports. One function, so the key
## a rung is looked up under is the key it is saved under.
static func _opentopo_cache_source(base_url: String, dem_name: String) -> String:
	if base_url == OPENTOPO_USGS_URL:
		return "opentopo_usgs1" if dem_name == "USGS1m" else "opentopo_usgs10"
	return "opentopo_%s" % dem_name


func _request_open_meteo(lat: float, lon: float, half_extent_m: float,
		grid_n: int, key: String, tag: String, req: Dictionary = {}) -> void:
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
		"req": req,
		"seq": _next_job_seq(),
	}
	_busy = true
	_ensure_pool()
	for w in POOL_SIZE:
		_dispatch_next(w)


func _next_job_seq() -> int:
	_job_seq += 1
	return _job_seq


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
		headers: PackedStringArray, body: PackedByteArray, worker: int) -> void:
	if _job.is_empty() or str(_job.get("source", "")) != "openmeteo":
		return
	var batch: int = _job["worker_batch"][worker]
	if batch < 0:
		return
	var body_text := body.get_string_from_utf8()
	if response_code == 429 and _is_openmeteo_daily_limit(response_code, body_text):
		_openmeteo_daily_exhausted = true
		_fail("Open-Meteo daily elevation quota exceeded — add OpenTopography key or try tomorrow")
		return
	# A dropped connection, a timeout, a throttle (429) or a gateway error
	# (502/503/504) is TRANSIENT: retry the batch with backoff. A network blip
	# on one of ~90 batches used to fail the whole DEM and flatten the world.
	if result != HTTPRequest.RESULT_SUCCESS or response_code == 429 or response_code >= 500:
		var retries: Dictionary = _job["retries"]
		var n := int(retries.get(batch, 0)) + 1
		retries[batch] = n
		if n > MAX_RETRIES:
			_fail("Open-Meteo %s after %d retries" % [_http_what(result, response_code), MAX_RETRIES])
			return
		var delay := _jittered(retry_delay_s(n, headers))
		push_warning("ElevationService: Open-Meteo batch %d %s — retry %d in %.0f s" % [
			batch, _http_what(result, response_code), n, delay])
		_after(delay, func() -> void:
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
		grid_n: int, key: String, tag: String, dem_name: String, base_url: String,
		req: Dictionary = {}) -> void:
	var bbox := GeoMath.bbox_for(lat, lon, half_extent_m)
	var api_key := _opentopo_key()
	if api_key.is_empty():
		_job = {"tag": tag}
		_fail("OpenTopography API key missing in user://terrain_config.cfg")
		return
	# A big global square goes up as a few tiles: one AAIGrid of a 180 km COP90
	# square is ~4.5 M cells (~35 MB of ASCII), slow enough that OpenTopography's
	# gateway answers 502 / the request times out, and the world loaded flat.
	var tiles: Array = [{"own": bbox, "req": bbox}]
	if base_url == OPENTOPO_GLOBAL_URL:
		tiles = tile_bboxes(bbox, dem_name, OPENTOPO_MAX_TILE_CELLS)
	var out := PackedFloat32Array()
	out.resize(grid_n * grid_n)
	out.fill(NAN)
	_job = {
		"source": "opentopo",
		"key": key,
		"cache_source": _opentopo_cache_source(base_url, dem_name),
		"tag": tag,
		"target_n": grid_n,
		"retries": 0,
		"dem_name": dem_name,
		"base_url": base_url,
		"api_key": api_key,
		"lat": lat,
		"lon": lon,
		"half_extent_m": half_extent_m,
		"bbox": bbox,
		"tiles": tiles,
		"tile_i": 0,
		"out": out,
		"req": req,
		"seq": _next_job_seq(),
	}
	_busy = true
	_ensure_opentopo_http()
	# 1 m AAIGrid is ~190 MB of ASCII over a 3 km square — 180 s is not enough
	# headroom for that on a slow link.
	_opentopo_http.timeout = 600.0 if dem_name == "USGS1m" else 180.0
	print("ElevationService: OpenTopography %s fetch (%.0f km square%s) …" % [
		dem_name, half_extent_m * 2.0 / 1000.0,
		"" if tiles.size() == 1 else ", %d tiles" % tiles.size()])
	_fire_opentopo_tile()


func _fire_opentopo_tile() -> void:
	var tiles: Array = _job["tiles"]
	var tile: Dictionary = tiles[int(_job["tile_i"])]
	_job["url"] = _build_opentopo_url(str(_job["base_url"]), str(_job["dem_name"]),
		tile["req"], str(_job["api_key"]))
	var err := _opentopo_http.request(str(_job["url"]))
	if err != OK:
		if _advance_ladder("HTTPRequest error %d" % err):
			return
		_fail("HTTPRequest error %d" % err)


static func _build_opentopo_url(base_url: String, dem_name: String, bbox: Dictionary,
		api_key: String) -> String:
	if base_url == OPENTOPO_USGS_URL:
		return "%s?datasetName=%s&south=%.6f&north=%.6f&west=%.6f&east=%.6f&outputFormat=AAIGrid&API_Key=%s" % [
			base_url, dem_name, bbox["south"], bbox["north"], bbox["west"], bbox["east"], api_key]
	return "%s?demtype=%s&south=%.6f&north=%.6f&west=%.6f&east=%.6f&outputFormat=AAIGrid&API_Key=%s" % [
		base_url, dem_name, bbox["south"], bbox["north"], bbox["west"], bbox["east"], api_key]


## Source cell size in degrees for a global/USGS product (0 = projected/unknown).
static func dem_cell_deg(dem_name: String) -> float:
	match dem_name:
		"SRTMGL1", "SRTMGL1_E", "COP30", "NASADEM", "AW3D30", "AW3D30_E":
			return 1.0 / 3600.0
		"SRTMGL3", "COP90":
			return 3.0 / 3600.0
		"USGS10m":
			return 1.0 / 10800.0
	return 0.0


## Split a bbox into k×k tiles so no single AAIGrid exceeds `max_cells` source
## cells. Each tile: "own" = its exact share (target samples are taken from the
## tile that owns them), "req" = own padded by two source cells so bilinear
## sampling at a seam has neighbours on both sides. k is capped at 4 (16 calls).
static func tile_bboxes(bbox: Dictionary, dem_name: String, max_cells: float) -> Array:
	var west := float(bbox["west"])
	var east := float(bbox["east"])
	var north := float(bbox["north"])
	var south := float(bbox["south"])
	var cell := dem_cell_deg(dem_name)
	var k := 1
	if cell > 0.0 and max_cells > 0.0:
		var cells := ((east - west) / cell) * ((north - south) / cell)
		k = clampi(int(ceil(sqrt(cells / max_cells))), 1, 4)
	var pad := cell * 2.0
	var out: Array = []
	for r in k:
		for c in k:
			var own := {
				"west": lerpf(west, east, float(c) / float(k)),
				"east": lerpf(west, east, float(c + 1) / float(k)),
				"north": lerpf(north, south, float(r) / float(k)),
				"south": lerpf(north, south, float(r + 1) / float(k)),
			}
			var padded := {
				"west": float(own["west"]) - pad, "east": float(own["east"]) + pad,
				"north": float(own["north"]) + pad, "south": float(own["south"]) - pad,
			}
			out.append({"own": own, "req": padded if k > 1 else own})
	return out


## Fill the target_n² samples of `full_bbox` that fall inside `own` from one
## geographic AAIGrid tile. Returns how many samples were written.
static func sample_tile_into(out: PackedFloat32Array, target_n: int, full_bbox: Dictionary,
		parsed: Dictionary, own: Dictionary) -> int:
	var cols := int(parsed.get("cols", 0))
	var rows := int(parsed.get("rows", 0))
	var src: PackedFloat32Array = parsed.get("grid", PackedFloat32Array())
	var xll := float(parsed.get("xllcorner", NAN))
	var yll := float(parsed.get("yllcorner", NAN))
	var cell := float(parsed.get("cellsize", NAN))
	if cols <= 0 or rows <= 0 or src.size() != cols * rows or is_nan(xll) or is_nan(yll) \
			or is_nan(cell) or cell <= 0.0 or target_n < 2:
		return 0
	var north := float(full_bbox["north"])
	var south := float(full_bbox["south"])
	var west := float(full_bbox["west"])
	var east := float(full_bbox["east"])
	var eps := 1e-9
	var inv := 1.0 / float(target_n - 1)
	var n := 0
	for r in target_n:
		var lat := lerpf(north, south, float(r) * inv)
		if lat > float(own["north"]) + eps or lat < float(own["south"]) - eps:
			continue
		for c in target_n:
			var lon := lerpf(west, east, float(c) * inv)
			if lon < float(own["west"]) - eps or lon > float(own["east"]) + eps:
				continue
			var fx := (lon - xll) / cell - 0.5
			var fy := (yll + float(rows) * cell - lat) / cell - 0.5
			out[r * target_n + c] = _sample_grid_bilinear(src, cols, rows, fx, fy)
			n += 1
	return n


func _ensure_opentopo_http() -> void:
	if _opentopo_http != null and is_instance_valid(_opentopo_http):
		return
	_opentopo_http = HTTPRequest.new()
	_opentopo_http.timeout = 180.0
	add_child(_opentopo_http)
	_opentopo_http.request_completed.connect(_on_opentopo_completed)


func _on_opentopo_completed(result: int, response_code: int,
		headers: PackedStringArray, body: PackedByteArray) -> void:
	if _job.is_empty() or str(_job.get("source", "")) != "opentopo":
		return
	var body_text := body.get_string_from_utf8()
	if result == HTTPRequest.RESULT_TIMEOUT:
		# Too slow at this size: a coarser product is the cure, not a 2nd wait.
		if _advance_ladder("timed out after %.0f s" % _opentopo_http.timeout):
			return
		_fail("OpenTopography timed out")
		return
	if result != HTTPRequest.RESULT_SUCCESS or response_code == 429 or response_code >= 500:
		var n := int(_job.get("retries", 0)) + 1
		_job["retries"] = n
		var what := _http_what(result, response_code)
		if n > MAX_RETRIES:
			if _advance_ladder("%s after %d retries" % [what, MAX_RETRIES]):
				return
			_fail("OpenTopography %s after %d retries" % [what, MAX_RETRIES])
			return
		var delay := _jittered(retry_delay_s(n, headers))
		push_warning("ElevationService: OpenTopography %s %s — retry %d in %.0f s" % [
			str(_job.get("dem_name", "")), what, n, delay])
		_after(delay, _fire_opentopo_tile)
		return
	if response_code != 200:
		var preview := body_text.substr(0, min(body_text.length(), 240)).strip_edges()
		if _advance_ladder("HTTP %d: %s" % [response_code, preview], true):
			return
		_fail("OpenTopography HTTP %d: %s" % [response_code, preview])
		return
	var target_n := int(_job.get("target_n", DEFAULT_GRID_N))
	var key := str(_job.get("key", ""))
	var tag := str(_job.get("tag", "base"))
	var bbox: Dictionary = _job["bbox"]
	var tiles: Array = _job["tiles"]
	var tile_i := int(_job["tile_i"])
	var parsed := parse_aaigrid(body_text)
	body_text = ""
	if parsed.is_empty():
		if _advance_ladder("AAIGrid parse failed (%d bytes)" % body.size(), true):
			return
		_fail("opentopo parse failed (%d bytes)" % body.size())
		return
	var grid := PackedFloat32Array()
	if tiles.size() == 1:
		var src: PackedFloat32Array = parsed["grid"]
		if not grid_is_usable(src, int(parsed["cols"]), int(parsed["rows"])):
			if _advance_ladder("DEM has no usable relief", true):
				return
			_fail("elevation grid has no usable relief")
			return
		# Georeference into the requested bbox so OSM metres stay registered to
		# DEM (OpenTopo AAIGrid corners are cell-snapped and often ≠ the request).
		grid = resample_aaigrid_to_bbox(parsed, bbox, target_n)
		if grid.is_empty():
			if aaigrid_is_projected(parsed):
				# A projected grid we could not place must NOT be stretch-fitted onto
				# the bbox — that misregisters the terrain against OSM and imagery
				# while looking perfectly plausible. Drop a rung instead.
				if _advance_ladder("projected AAIGrid could not be georeferenced", true):
					return
				_fail("projected DEM could not be georeferenced")
				return
			grid = TerrainBuilder.resample(src, int(parsed["cols"]), int(parsed["rows"]), target_n)
	else:
		var out: PackedFloat32Array = _job["out"]
		if aaigrid_is_projected(parsed) \
				or sample_tile_into(out, target_n, bbox, parsed, (tiles[tile_i] as Dictionary)["own"]) <= 0:
			if _advance_ladder("tile %d/%d could not be georeferenced" % [tile_i + 1, tiles.size()], true):
				return
			_fail("tiled DEM could not be georeferenced")
			return
		_job["out"] = out
		elevation_progress.emit(tile_i + 1, tiles.size())
		if tile_i + 1 < tiles.size():
			_job["tile_i"] = tile_i + 1
			_job["retries"] = 0
			_after(DISPATCH_DELAY, _fire_opentopo_tile)
			return
		grid = out
		if not grid_is_usable(grid, target_n, target_n):
			if _advance_ladder("tiled DEM has no usable relief", true):
				return
			_fail("elevation grid has no usable relief")
			return
	_save_cache(key, grid, target_n, target_n)
	_busy = false
	_job = {}
	elevation_ready.emit(key, grid, target_n, target_n, tag)
	_start_next()


## Move the current request to the next source of its ladder (source_ladder).
## `permanent` = the failure means this product is not available here (bad
## request, no coverage, unparseable/unplaceable body) as opposed to a
## transient network or rate-limit condition. It gates the USGS1m negative
## cache only: two real reasons a USGS1m request comes back rejected, both
## permanent for THIS key/site — (a) no 3DEP lidar project ever flew it, or (b)
## OpenTopography's access policy: USGS1m returns HTTP 401 "restricted for
## academics" for an ordinary self-registered key, even with real coverage.
## The recorded reason (usgs1m_miss_reason) is what lets the UI tell the two
## apart. A 429 or a dropped connection says nothing about coverage, and
## latching one would permanently downgrade the site over a blip.
func _advance_ladder(reason: String, permanent: bool = false) -> bool:
	if _job.is_empty():
		return false
	var req: Dictionary = _job.get("req", {})
	if req.is_empty():
		return false
	if permanent and str(_job.get("dem_name", "")) == "USGS1m":
		_mark_usgs1m_missing(float(req["lat"]), float(req["lon"]), reason)
	var ladder: Array = req["ladder"]
	var next := int(req["rung"]) + 1
	if next >= ladder.size():
		return false
	var cur: Dictionary = ladder[int(req["rung"])]
	var nxt: Dictionary = ladder[next]
	push_warning("ElevationService: '%s' %s failed (%s) — trying %s" % [
		str(req["tag"]), str(cur["cache_source"]), reason, str(nxt["cache_source"])])
	if _opentopo_http != null and is_instance_valid(_opentopo_http):
		_opentopo_http.cancel_request()
	for http in _pool:
		if is_instance_valid(http):
			http.cancel_request()
	var next_req := req.duplicate()
	next_req["rung"] = next
	_job = {}
	_busy = true
	_begin_rung(next_req)
	return true


## Seconds to wait before retry `attempt` (1-based): the server's Retry-After
## when it sent one (clamped 1–120 s), else RETRY_BACKOFF doubling per attempt.
static func retry_delay_s(attempt: int, headers: PackedStringArray = PackedStringArray()) -> float:
	for h in headers:
		var low := h.to_lower()
		if low.begins_with("retry-after:"):
			var v := h.substr(h.find(":") + 1).strip_edges()
			if v.is_valid_float():
				return clampf(float(v), 1.0, 120.0)
	return RETRY_BACKOFF * pow(2.0, float(maxi(attempt, 1) - 1))


## Spread simultaneous retries a little (up to +25 %).
static func _jittered(delay: float) -> float:
	return delay * (1.0 + randf() * 0.25)


static func _http_what(result: int, response_code: int) -> String:
	if result != HTTPRequest.RESULT_SUCCESS:
		return "network error (result %d)" % result
	return "HTTP %d" % response_code


static func parse_aaigrid(text: String) -> Dictionary:
	var cols := 0
	var rows := 0
	var nodata := -9999.0
	var xll := NAN
	var yll := NAN
	var cell := NAN
	var xll_is_center := false
	var yll_is_center := false
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
				elif low.begins_with("xllcorner"):
					xll = TerrainBuilder.variant_to_float(parts[1], NAN)
					xll_is_center = false
				elif low.begins_with("yllcorner"):
					yll = TerrainBuilder.variant_to_float(parts[1], NAN)
					yll_is_center = false
				elif low.begins_with("xllcenter"):
					xll = TerrainBuilder.variant_to_float(parts[1], NAN)
					xll_is_center = true
				elif low.begins_with("yllcenter"):
					yll = TerrainBuilder.variant_to_float(parts[1], NAN)
					yll_is_center = true
				elif low.begins_with("cellsize"):
					cell = TerrainBuilder.variant_to_float(parts[1], NAN)
			continue
		in_data = true
		for tok in line.split(" ", false):
			if tok.is_empty():
				continue
			var v := TerrainBuilder.variant_to_float(tok, nodata)
			values.append(NAN if is_equal_approx(v, nodata) else v)
	if cols <= 0 or rows <= 0 or values.size() != cols * rows:
		return {}
	# Normalize center headers to SW corner.
	if not is_nan(cell) and cell > 0.0:
		if xll_is_center and not is_nan(xll):
			xll -= cell * 0.5
		if yll_is_center and not is_nan(yll):
			yll -= cell * 0.5
	return {
		"cols": cols, "rows": rows, "grid": values,
		"xllcorner": xll, "yllcorner": yll, "cellsize": cell,
	}


## True when an AAIGrid header carries PROJECTED metres (UTM eastings/northings)
## instead of geographic degrees. USGS 3DEP 1 m lidar products are published in
## UTM; every other DEM OpenTopography serves us (SRTM/COP/USGS10m) is in
## degrees, and the two must be indexed differently.
static func aaigrid_is_projected(parsed: Dictionary) -> bool:
	var xll := float(parsed.get("xllcorner", NAN))
	var yll := float(parsed.get("yllcorner", NAN))
	var cell := float(parsed.get("cellsize", NAN))
	if is_nan(xll) or is_nan(yll) or is_nan(cell):
		return false
	# A geographic grid has |lon| <= 180, |lat| <= 90 and a sub-degree cell.
	# Any of those blown out means the header is in projected metres.
	return absf(xll) > 180.0 or absf(yll) > 90.0 or cell > 1.0


## Resample a UTM AAIGrid onto the requested lat/lon bbox: every target sample is
## forward-projected into the grid's zone and indexed in metres.
##
## This exists because feeding a UTM header through the geographic path is a
## SILENT failure, not a loud one — `(lon - 617228) / 1.0` clamps every sample
## onto one corner cell, so the whole grid comes back as a single repeated value.
## grid_is_usable then rejects it as "no usable relief" and the loader quietly
## falls back, which reads as "1 m DEM did nothing" rather than as a bug.
static func _resample_projected_aaigrid(parsed: Dictionary, bbox: Dictionary,
		target_n: int) -> PackedFloat32Array:
	var cols := int(parsed.get("cols", 0))
	var rows := int(parsed.get("rows", 0))
	var src: PackedFloat32Array = parsed.get("grid", PackedFloat32Array())
	var xll := float(parsed.get("xllcorner", 0.0))
	var yll := float(parsed.get("yllcorner", 0.0))
	var cell := float(parsed.get("cellsize", 1.0))
	var north := float(bbox.get("north", 0.0))
	var south := float(bbox.get("south", 0.0))
	var east := float(bbox.get("east", 0.0))
	var west := float(bbox.get("west", 0.0))
	# One zone for the whole patch — a bbox near a zone edge must be projected
	# into the zone the GRID is in, not each sample into its own.
	var zone := GeoMath.utm_zone_for_lon((west + east) * 0.5)
	# Sanity gate: the requested centre has to land inside the returned grid. If
	# it does not, the header is in some other projection (State Plane, say) and
	# guessing would misregister the terrain against OSM and imagery — better to
	# bail and let the caller drop to a source we can place.
	var centre: Dictionary = GeoMath.lonlat_to_utm(
		(north + south) * 0.5, (west + east) * 0.5, zone)
	var cx := (float(centre["easting"]) - xll) / cell
	var cy := (yll + float(rows) * cell - float(centre["northing"])) / cell
	if cx < 0.0 or cx > float(cols) or cy < 0.0 or cy > float(rows):
		push_warning(("ElevationService: projected AAIGrid does not register as UTM zone %d "
			+ "(centre maps to %.0f,%.0f in a %dx%d grid) — cannot georeference") % [
			zone, cx, cy, cols, rows])
		return PackedFloat32Array()
	var out := PackedFloat32Array()
	out.resize(target_n * target_n)
	var inv := 1.0 / float(target_n - 1)
	for r in target_n:
		var lat := lerpf(north, south, float(r) * inv)
		for c in target_n:
			var lon := lerpf(west, east, float(c) * inv)
			var p: Dictionary = GeoMath.lonlat_to_utm(lat, lon, zone)
			# AAIGrid row 0 is north; xll/yll name the SOUTH-west corner.
			var fx := (float(p["easting"]) - xll) / cell - 0.5
			var fy := (yll + float(rows) * cell - float(p["northing"])) / cell - 0.5
			out[r * target_n + c] = _sample_grid_bilinear(src, cols, rows, fx, fy)
	return out


## Sample an AAIGrid into a target_n² grid covering `bbox` {north,south,east,west}.
## Falls back to empty when georef headers are missing. Dispatches on the header's
## CRS: geographic degrees inline, projected metres via _resample_projected_aaigrid.
static func resample_aaigrid_to_bbox(parsed: Dictionary, bbox: Dictionary,
		target_n: int) -> PackedFloat32Array:
	var cols := int(parsed.get("cols", 0))
	var rows := int(parsed.get("rows", 0))
	var src: PackedFloat32Array = parsed.get("grid", PackedFloat32Array())
	var xll := float(parsed.get("xllcorner", NAN))
	var yll := float(parsed.get("yllcorner", NAN))
	var cell := float(parsed.get("cellsize", NAN))
	if cols <= 0 or rows <= 0 or src.size() != cols * rows:
		return PackedFloat32Array()
	if is_nan(xll) or is_nan(yll) or is_nan(cell) or cell <= 0.0 or target_n < 2:
		return PackedFloat32Array()
	if aaigrid_is_projected(parsed):
		return _resample_projected_aaigrid(parsed, bbox, target_n)
	var north := float(bbox.get("north", 0.0))
	var south := float(bbox.get("south", 0.0))
	var east := float(bbox.get("east", 0.0))
	var west := float(bbox.get("west", 0.0))
	var out := PackedFloat32Array()
	out.resize(target_n * target_n)
	var inv := 1.0 / float(target_n - 1)
	for r in target_n:
		var lat := lerpf(north, south, float(r) * inv)
		for c in target_n:
			var lon := lerpf(west, east, float(c) * inv)
			# AAIGrid row 0 is north. Column grows east from xll.
			var fx := (lon - xll) / cell - 0.5
			var fy := (yll + float(rows) * cell - lat) / cell - 0.5
			out[r * target_n + c] = _sample_grid_bilinear(src, cols, rows, fx, fy)
	return out


static func _sample_grid_bilinear(grid: PackedFloat32Array, cols: int, rows: int,
		fx: float, fy: float) -> float:
	if cols <= 0 or rows <= 0 or grid.is_empty():
		return NAN
	var x0 := clampi(int(floor(fx)), 0, cols - 1)
	var y0 := clampi(int(floor(fy)), 0, rows - 1)
	var x1 := mini(x0 + 1, cols - 1)
	var y1 := mini(y0 + 1, rows - 1)
	var tx := clampf(fx - float(x0), 0.0, 1.0)
	var ty := clampf(fy - float(y0), 0.0, 1.0)
	var v00 := grid[y0 * cols + x0]
	var v10 := grid[y0 * cols + x1]
	var v01 := grid[y1 * cols + x0]
	var v11 := grid[y1 * cols + x1]
	# Prefer neighbours when a corner is NODATA/NaN.
	if is_nan(v00) and is_nan(v10) and is_nan(v01) and is_nan(v11):
		return NAN
	if is_nan(v00):
		v00 = v10 if not is_nan(v10) else (v01 if not is_nan(v01) else v11)
	if is_nan(v10):
		v10 = v00
	if is_nan(v01):
		v01 = v11 if not is_nan(v11) else v00
	if is_nan(v11):
		v11 = v01
	var a := lerpf(v00, v10, tx)
	var b := lerpf(v01, v11, tx)
	return lerpf(a, b, ty)


func _after(delay: float, cb: Callable) -> void:
	var seq := int(_job.get("seq", -1))
	var fire := func() -> void:
		if _busy and not _job.is_empty() and int(_job.get("seq", -2)) == seq:
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


## Older on-disk DEM for the same site/params (e.g. v3 after a v4 bump).
static func _legacy_dem_cache_path(current_path: String) -> String:
	var fn := current_path.get_file()
	var needle := "dem_%s_" % CACHE_VERSION
	if not fn.begins_with(needle):
		return ""
	# Walk back a few versions; stop at the first file that exists.
	for ver in ["v3", "v2", "v1"]:
		if ver == CACHE_VERSION:
			continue
		var alt := "%s/%s" % [current_path.get_base_dir(), fn.replace(needle, "dem_%s_" % ver)]
		if FileAccess.file_exists(alt):
			return alt
	return ""


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
	return _sanitize_api_key(_read_config_api_key())
