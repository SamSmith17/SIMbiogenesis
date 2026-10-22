extends Node

## WeatherService — real historical weather from the Open-Meteo archive API.
##
## Fetches one calendar year of hourly data for the active sim location and
## exposes time-indexed accessors the simulation samples every tick. Data is
## cached under user://weather_cache/ so each location/year is fetched once.
##
## API: https://open-meteo.com/ — archive endpoint, no key required,
## CC BY 4.0. Archive coverage runs from 1940 to ~5 days before today, so a
## sim year whose data is incomplete (the current or a future year)
## substitutes the latest complete calendar year as a representative real
## weather year (`effective_year`).
##
## Offline behavior: every accessor returns NAN when data is unavailable;
## consumers must keep their synthetic fallbacks.

signal weather_data_ready(latitude: float, longitude: float, year: int)
## The current calendar year's partial archive landed (see ensure_current_year_archive).
signal current_year_archive_ready(latitude: float, longitude: float, year: int)
signal weather_fetch_failed(reason: String)
## Emitted when a fresh forecast window is available for the current location.
signal forecast_data_ready(latitude: float, longitude: float)
signal forecast_fetch_failed(reason: String)
## Emitted when the per-day-of-year temperature record book is ready.
signal records_ready(latitude: float, longitude: float)
signal generation_progress(year: int, month: int, frac: float)
signal generation_complete(years: Array)
signal training_archives_ready(latitude: float, longitude: float)
signal training_fetch_failed(reason: String)
signal training_archives_progress(loaded: int, total: int)
signal generation_training_started()

const ARCHIVE_URL := "https://archive-api.open-meteo.com/v1/archive"
const FORECAST_URL := "https://api.open-meteo.com/v1/forecast"
const HOURLY_VARS := "shortwave_radiation,diffuse_radiation,wind_speed_10m,windgusts_10m,wind_direction_10m,temperature_2m,relative_humidity_2m,precipitation,cloud_cover,snowfall,snow_depth,dew_point_2m,cloud_cover_low"
## Forecast-only extras (archive API returns null for 80 m / 180 m fields and
## for `visibility`). Visibility is the model's own fog diagnosis — over CONUS
## the forecast feed is HRRR, whose visibility caught the Walton valley fog
## (100–500 m) while its T/RH stayed 3–4 °C off saturation.
const FORECAST_EXTRA_VARS := "wind_direction_80m,wind_direction_180m,wind_speed_80m,wind_speed_180m,visibility"
const FORECAST_HOURLY_VARS := HOURLY_VARS + "," + FORECAST_EXTRA_VARS
## Daily variables fetched for the 1940-present record book (separate request).
const RECORDS_DAILY_VARS := "temperature_2m_max,temperature_2m_min,precipitation_sum"
## Bump when RECORDS_DAILY_VARS changes so old record caches are retired.
const RECORDS_CACHE_VERSION := "v2"
const CACHE_DIR := "user://weather_cache"
## Reject / delete cache blobs larger than this (guards corrupt or foreign files).
const MAX_CACHE_BYTES := 25 * 1024 * 1024
## Bump this suffix when HOURLY_VARS changes so old cached responses are retired.
## v4 = added snowfall + snow_depth for seasonal snow visuals.
## v5 = added dew_point_2m + cloud_cover_low (microclimate fog diagnosis — ERA5
## reports radiation fog as 100 % LOW cloud at RH 100 %).
const CACHE_VERSION := "v5"
## Bump when forecast cache envelope changes (stored Open-Meteo JSON + metadata).
## v3 = added dew_point_2m, cloud_cover_low, visibility; past_days 5 → 14.
const FORECAST_CACHE_VERSION := "v3"
## Re-fetch the live forecast when older than this (models update several times/day).
const FORECAST_MAX_AGE_SEC := 6 * 3600
## Bump when the generation schema/output changes. v11 = selectable engine
## (parametric vs block-bootstrap resampler) recorded in the cache key + payload.
const GEN_CACHE_VERSION := "v11"
## Synthesis engines (Phase 7). PARAMETRIC = StochasticWeatherGenerator (WGEN-style);
## RESAMPLER = WeatherResampler (k-NN / block bootstrap of real archive days).
enum GenEngine { PARAMETRIC, RESAMPLER }
## Persisted user default engine choice (gitignored user pref).
const ENGINE_CONFIG_PATH := "user://weather_gen_engine.cfg"
## Archive years used to train the stochastic generator baseline.
const TRAINING_YEAR_COUNT := 5
## Forecast window: 14 past days + 16 future days (~30-day sliding window). The
## past days keep the forecast model's analysis (incl. its `visibility`) for
## recent nights — the archive has no visibility at all.
const FORECAST_PAST_DAYS := 14
const FORECAST_FUTURE_DAYS := 16
## Generated weather yields to real forecast for this many hours ahead of now.
const FORECAST_OVERRIDE_DAYS := 10
## The current calendar year's PARTIAL archive (Jan 1 → today; ERA5T lags ~5
## days, those hours come back null) is refetched once a day. Without it a 2026
## date outside the forecast window silently showed 2025's weather, because
## effective_year() maps the current year to the last complete one.
const CURRENT_YEAR_MAX_AGE_SEC := 24 * 3600

## Locations within this many degrees of the loaded dataset count as covered
## (~5.5 km N-S). Archive resolution is ~11 km, so this is conservative.
const COVERAGE_EPSILON_DEG := 0.05

## How often to check whether the sim location/year drifted from the loaded
## dataset (location picker writes straight to Main's lat/lon).
const LOCATION_POLL_INTERVAL := 3.0

## Cumulative days before each month, common year. Never index an hourly
## series with this directly: go through day_of_year0 / hour_index, which know
## the series' own layout (an Open-Meteo leap-year archive has 8784 hours, and
## reading it with this table put every date after Feb 29 one day early).
const _DAYS_BEFORE_MONTH: Array[int] = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
## Hours in a common / leap year — the two lengths a full archive can have.
const HOURS_COMMON_YEAR := 8760
const HOURS_LEAP_YEAR := 8784
## First hour of Feb 29 in a leap-year layout (31 + 28 days).
const FEB29_HOUR := 59 * 24

var _http: HTTPRequest = null
var _fetching: bool = false

## Loaded dataset descriptor + per-variable hour-of-year arrays (8760 floats,
## 8784 for a leap-year archive; missing samples are NAN).
var _data_lat: float = NAN
var _data_lon: float = NAN
var _data_year: int = 0
var _series: Dictionary = {}  # var name -> PackedFloat32Array

## Partial archive for the CURRENT calendar year (see CURRENT_YEAR_MAX_AGE_SEC).
## Same hour-of-year layout as _series; hours not yet published are NAN.
var _http_cy: HTTPRequest = null
var _fetching_cy: bool = false
var _cy_series: Dictionary = {}
var _cy_year: int = 0
var _cy_lat: float = NAN
var _cy_lon: float = NAN
var _cy_fetched_unix: int = 0

## Forecast window — separate HTTPRequest, separate series.
var _http_forecast: HTTPRequest = null
var _fetching_forecast: bool = false
## Per-variable arrays for the forecast window (length = FORECAST_PAST_DAYS +
## FORECAST_FUTURE_DAYS days × 24 h ≈ 504 entries).
var _forecast_series: Dictionary = {}
## Hour-of-year (0–8783) of the first forecast entry; -1 = no data.
var _forecast_start_hoy: int = -1
## Calendar year the forecast window starts in (for Dec→Jan wrapping).
var _forecast_start_year: int = 0
var _forecast_lat: float = NAN
var _forecast_lon: float = NAN
## "YYYY-MM-DD" of the day this forecast was fetched; triggers daily refresh.
var _forecast_fetched_date: String = ""
## Unix time of last successful forecast load (network or cache).
var _forecast_fetched_unix: int = 0
## Raw sim year tracked from Main (before effective_year substitution).
var _sim_year: int = 0

## Temperature record book (Phase 4). Keyed "MM-DD" → { high, high_year, low, low_year }.
## Covers 1940–present; refreshed once per calendar year (current year accumulates).
var _http_records: HTTPRequest = null
var _fetching_records: bool = false
var _records: Dictionary = {}
var _records_lat: float = NAN
var _records_lon: float = NAN
var _records_fetch_year: int = 0   # calendar year at last successful fetch

var _main_node:   Node  = null
var _poll_acc:    float = 0.0
var _climate_svc: Node  = null  # cached ClimateProjectionService reference

## Stochastic generated future years (year int -> var -> PackedFloat32Array 8760).
var _generated: Dictionary = {}
## Future-column yearbook counts derived from hourly generated weather (Phase 8).
var _generated_yearbook: Dictionary = {}
## Untyped so it can hold either StochasticWeatherGenerator or WeatherResampler;
## both expose the same train/begin_year/generate_month/set_* contract.
var _gen_engine = null
var _gen_active: bool = false
var _gen_seed: int = 0
var _gen_scenario: int = 0
## Engine kind of the active generation run + the persisted user default.
var _gen_engine_kind: int = GenEngine.PARAMETRIC
var _default_engine_kind: int = GenEngine.PARAMETRIC
var _gen_lat: float = NAN
var _gen_lon: float = NAN
var _gen_start_year: int = 0
var _gen_num_years: int = 1
var _gen_cur_year: int = 0
var _gen_cur_month: int = 1
var _gen_working: Dictionary = {}
var _gen_years_queue: Array[int] = []
var _gen_years_done: Array[int] = []
## year int → Vector2i(first_month, last_month) generation span.
var _gen_year_plan: Dictionary = {}
var _gen_start_month: int = 1
## Hour-of-year (0–8783) when generated data takes over on the first tranche year.
var _gen_effective_hoy: int = 0

## Multi-year training archives for the stochastic generator.
var _http_training: HTTPRequest = null
var _fetching_training: bool = false
var _training_lat: float = NAN
var _training_lon: float = NAN
var _training_series: Dictionary = {}  # year int -> var -> PackedFloat32Array
var _training_fetch_queue: Array[int] = []
var _training_load_queue: Array[int] = []
var _training_load_active: bool = false
var _pending_generation: Dictionary = {}
var _gen_force_refresh: bool = false
var _gen_total_months: int = 0
var _gen_months_done: int = 0


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE_DIR))
	_load_engine_pref()
	_ensure_http()
	set_process(true)
	call_deferred("_bootstrap_weather_from_main")


## One-shot after the Main scene is in-tree (covers default scene coords that
## never went through apply_location, e.g. built-in maps without saved prefs).
func _bootstrap_weather_from_main() -> void:
	_resolve_main()
	if _main_node == null:
		return
	var lat_v: Variant = _main_node.get("latitude")
	var lon_v: Variant = _main_node.get("longitude")
	if lat_v == null or lon_v == null:
		return
	notify_location_changed(float(lat_v), float(lon_v))


## Persisted synthesis-engine default (Phase 7b).
func get_default_engine() -> int:
	return _default_engine_kind


func set_default_engine(kind: int) -> void:
	_default_engine_kind = clampi(kind, 0, GenEngine.size() - 1)
	var cfg := ConfigFile.new()
	cfg.set_value("weather_gen", "engine", _default_engine_kind)
	cfg.save(ENGINE_CONFIG_PATH)


func _load_engine_pref() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(ENGINE_CONFIG_PATH) != OK:
		return
	_default_engine_kind = clampi(int(cfg.get_value("weather_gen", "engine", GenEngine.PARAMETRIC)),
		0, GenEngine.size() - 1)


## Construct a fresh synthesis engine instance for the given kind.
func _make_engine(kind: int):
	if kind == GenEngine.RESAMPLER:
		return WeatherResampler.new()
	return StochasticWeatherGenerator.new()


## Short, stable filename tag distinguishing engine caches.
static func _engine_tag(kind: int) -> String:
	return "r" if kind == GenEngine.RESAMPLER else "p"


## Lazily create the HTTPRequest child so request_weather works even when
## called before _ready (e.g. from a SceneTree --script context).
func _ensure_http() -> void:
	if _http != null and is_instance_valid(_http):
		return
	_http = HTTPRequest.new()
	_http.timeout = 30.0
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)


func _ensure_http_forecast() -> void:
	if _http_forecast != null and is_instance_valid(_http_forecast):
		return
	_http_forecast = HTTPRequest.new()
	_http_forecast.timeout = 30.0
	add_child(_http_forecast)
	_http_forecast.request_completed.connect(_on_forecast_request_completed)


func _ensure_http_records() -> void:
	if _http_records != null and is_instance_valid(_http_records):
		return
	_http_records = HTTPRequest.new()
	_http_records.timeout = 60.0   # large response (~1-2 MB), allow extra time
	add_child(_http_records)
	_http_records.request_completed.connect(_on_records_request_completed)


func _process(delta: float) -> void:
	_poll_acc += delta
	if _poll_acc < LOCATION_POLL_INTERVAL:
		return
	_poll_acc = 0.0
	_resolve_main()
	if _main_node == null:
		return
	var lat: Variant = _main_node.get("latitude")
	var lon: Variant = _main_node.get("longitude")
	var yr: Variant = _main_node.get("year")
	if lat == null or lon == null:
		return
	_refresh_weather_datasets(float(lat), float(lon), int(yr) if yr != null else _current_calendar_year())


## Called from Main.apply_location() so forecast/archive refresh immediately on
## map load or location change instead of waiting for the next poll tick.
func notify_location_changed(lat: float, lon: float) -> void:
	_resolve_main()
	var yr := int(_main_node.get("year")) if _main_node != null and _main_node.get("year") != null \
		else _current_calendar_year()
	_refresh_weather_datasets(lat, lon, yr)


func _refresh_weather_datasets(lat: float, lon: float, raw_year: int) -> void:
	_sim_year = raw_year

	# Archive fetch (historical, effective_year substitution for current/future).
	if not _fetching:
		var want_year := effective_year(raw_year)
		if not (has_data() and covers(lat, lon) and _data_year == want_year):
			request_weather(lat, lon, want_year)

	# Live forecast: only when sim calendar year matches the real-world year.
	if raw_year == _current_calendar_year():
		ensure_forecast_fresh(lat, lon)
		ensure_current_year_archive(lat, lon)


## Load cached forecast if needed and request a network refresh when stale.
func ensure_forecast_fresh(lat: float, lon: float, force: bool = false) -> void:
	if not has_forecast() or _forecast_location_mismatch(lat, lon):
		_try_load_forecast_cache(lat, lon)
	if force or _forecast_is_stale(lat, lon):
		if not _fetching_forecast:
			request_forecast(lat, lon)


func _forecast_location_mismatch(lat: float, lon: float) -> bool:
	return is_nan(_forecast_lat) \
		or absf(lat - _forecast_lat) > COVERAGE_EPSILON_DEG \
		or absf(lon - _forecast_lon) > COVERAGE_EPSILON_DEG


func _forecast_is_stale(lat: float, lon: float) -> bool:
	if not has_forecast():
		return true
	if _forecast_location_mismatch(lat, lon):
		return true
	if _forecast_fetched_date != _today_date_str():
		return true
	if _forecast_fetched_unix <= 0:
		return true
	return Time.get_unix_time_from_system() - _forecast_fetched_unix > FORECAST_MAX_AGE_SEC


static func _forecast_cache_path(lat: float, lon: float) -> String:
	return "%s/forecast_%s_%.4f_%.4f.json" % [CACHE_DIR, FORECAST_CACHE_VERSION, lat, lon]


func _try_load_forecast_cache(lat: float, lon: float) -> bool:
	var text := _read_cache_text(_forecast_cache_path(lat, lon))
	if text.is_empty():
		return false
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return false
	var d := parsed as Dictionary
	if str(d.get("cache_version", "")) != FORECAST_CACHE_VERSION:
		return false
	if absf(float(d.get("lat", 999.0)) - lat) > COVERAGE_EPSILON_DEG \
			or absf(float(d.get("lon", 999.0)) - lon) > COVERAGE_EPSILON_DEG:
		return false
	var body_v: Variant = d.get("response_text", "")
	if str(body_v).is_empty():
		return false
	var fetched_date := str(d.get("fetched_date", ""))
	var fetched_unix := int(d.get("fetched_unix", 0))
	return parse_forecast_json(str(body_v), lat, lon, fetched_date, fetched_unix)


func _write_forecast_cache(response_text: String, lat: float, lon: float) -> void:
	var payload := {
		"cache_version": FORECAST_CACHE_VERSION,
		"fetched_date": _forecast_fetched_date,
		"fetched_unix": _forecast_fetched_unix,
		"lat": lat,
		"lon": lon,
		"response_text": response_text,
	}
	var f := FileAccess.open(_forecast_cache_path(lat, lon), FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(payload))
	f.close()


func _resolve_main() -> void:
	if _main_node != null and is_instance_valid(_main_node):
		return
	_main_node = null
	var root := get_tree().root
	for child in root.get_children():
		if "day_time" in child and "sun" in child:
			_main_node = child
			return
	var scene := get_tree().current_scene
	if scene and "day_time" in scene:
		_main_node = scene


static func _current_calendar_year() -> int:
	return int(Time.get_date_dict_from_system().year)


static func _today_date_str() -> String:
	var d := Time.get_date_dict_from_system()
	return "%d-%02d-%02d" % [int(d.year), int(d.month), int(d.day)]


## The calendar year actually fetched for a requested sim year: the archive
## lags ~5 days behind today, so any year without complete coverage maps to
## the latest complete year.
static func effective_year(sim_year: int) -> int:
	var today := Time.get_date_dict_from_system()
	var latest_complete: int = int(today.year) - 1
	if sim_year >= 1940 and sim_year <= latest_complete:
		return sim_year
	return latest_complete


## ---------------------------------------------------------------------------
## Fetch + cache
## ---------------------------------------------------------------------------

func _read_cache_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var nbytes := f.get_length()
	if nbytes <= 0 or nbytes > MAX_CACHE_BYTES:
		f.close()
		_delete_cache_file(path)
		return ""
	var text := f.get_as_text()
	f.close()
	return text


func _delete_cache_file(path: String) -> void:
	var global_path := ProjectSettings.globalize_path(path)
	if global_path.is_empty():
		return
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(global_path)


func request_weather(lat: float, lon: float, year: int) -> void:
	if _fetching:
		return
	# Cache hit?
	var cache_path := _cache_path(lat, lon, year)
	var text := _read_cache_text(cache_path)
	if not text.is_empty():
		if parse_archive_json(text, lat, lon, year):
			# Deferred so the emit timing matches the network path — a
			# consumer that connects right after request_weather() never
			# misses a cache-hit notification.
			weather_data_ready.emit.call_deferred(lat, lon, year)
			return
		# Corrupt cache — refetch below.
		_delete_cache_file(cache_path)
	_ensure_http()
	var url := "%s?latitude=%.4f&longitude=%.4f&start_date=%d-01-01&end_date=%d-12-31&hourly=%s&timezone=auto" \
		% [ARCHIVE_URL, lat, lon, year, year, HOURLY_VARS]
	var err := _http.request(url)
	if err != OK:
		# Deferred so callers that connect right after request_weather()
		# still receive the failure.
		weather_fetch_failed.emit.call_deferred("HTTPRequest error %d" % err)
		return
	_fetching = true
	# Stash what we asked for; applied on completion.
	set_meta("pending", {"lat": lat, "lon": lon, "year": year})


func _on_request_completed(result: int, response_code: int,
		_headers: PackedStringArray, body: PackedByteArray) -> void:
	_fetching = false
	var pending: Dictionary = get_meta("pending", {})
	var lat := float(pending.get("lat", 0.0))
	var lon := float(pending.get("lon", 0.0))
	var year := int(pending.get("year", 0))
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		weather_fetch_failed.emit("fetch failed (result %d, HTTP %d)" % [result, response_code])
		return
	var text := body.get_string_from_utf8()
	if not parse_archive_json(text, lat, lon, year):
		weather_fetch_failed.emit("unparseable archive response")
		return
	# Persist raw response for next time.
	var f := FileAccess.open(_cache_path(lat, lon, year), FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()
	weather_data_ready.emit(lat, lon, year)


static func _cache_path(lat: float, lon: float, year: int) -> String:
	return "%s/om_%s_%.2f_%.2f_%d.json" % [CACHE_DIR, CACHE_VERSION, lat, lon, year]


## ---------------------------------------------------------------------------
## Forecast fetch
## ---------------------------------------------------------------------------

func request_forecast(lat: float, lon: float) -> void:
	if _fetching_forecast:
		return
	_ensure_http_forecast()
	var url := "%s?latitude=%.4f&longitude=%.4f&hourly=%s&forecast_days=%d&past_days=%d&timezone=auto" \
		% [FORECAST_URL, lat, lon, FORECAST_HOURLY_VARS, FORECAST_FUTURE_DAYS, FORECAST_PAST_DAYS]
	var err := _http_forecast.request(url)
	if err != OK:
		forecast_fetch_failed.emit.call_deferred("HTTPRequest error %d" % err)
		return
	_fetching_forecast = true
	set_meta("pending_forecast", {"lat": lat, "lon": lon})


func _on_forecast_request_completed(result: int, response_code: int,
		_headers: PackedStringArray, body: PackedByteArray) -> void:
	_fetching_forecast = false
	var pending: Dictionary = get_meta("pending_forecast", {})
	var lat := float(pending.get("lat", 0.0))
	var lon := float(pending.get("lon", 0.0))
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		forecast_fetch_failed.emit("fetch failed (result %d, HTTP %d)" % [result, response_code])
		return
	var text := body.get_string_from_utf8()
	if not parse_forecast_json(text, lat, lon):
		forecast_fetch_failed.emit("unparseable forecast response")
		return
	_write_forecast_cache(text, lat, lon)
	forecast_data_ready.emit(lat, lon)


## Parse an Open-Meteo forecast response (hourly, timezone=auto) into the
## sliding forecast window. Public so smoke tests can feed canned JSON.
## Stores hour-of-year of the first entry as _forecast_start_hoy so sample()
## can compute array offsets by pure calendar arithmetic (no UTC conversion).
func parse_forecast_json(text: String, lat: float, lon: float,
		fetched_date: String = "", fetched_unix: int = -1) -> bool:
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return false
	var hourly: Dictionary = (parsed as Dictionary).get("hourly", {}) as Dictionary
	if hourly.is_empty():
		return false
	var times: Array = hourly.get("time", []) as Array
	if times.is_empty():
		return false
	# Parse first timestamp "YYYY-MM-DDTHH:MM" to get start position.
	var first_ts := str(times[0])
	var t_parts := first_ts.split("T")
	if t_parts.size() < 2:
		return false
	var d_parts := t_parts[0].split("-")
	var h_parts := t_parts[1].split(":")
	if d_parts.size() < 3 or h_parts.is_empty():
		return false
	var start_year := int(d_parts[0])
	var start_month := clampi(int(d_parts[1]), 1, 12)
	var start_day := clampi(int(d_parts[2]), 1, 31)
	var start_hour := clampi(int(h_parts[0]), 0, 23)
	var start_doy := day_of_year0(start_month, start_day, is_leap_year(start_year))
	var start_hoy := start_doy * 24 + start_hour
	# Parse per-variable arrays.
	var new_series: Dictionary = {}
	for var_name in FORECAST_HOURLY_VARS.split(","):
		var raw: Array = hourly.get(var_name, []) as Array
		if raw.is_empty():
			continue
		var arr := PackedFloat32Array()
		arr.resize(raw.size())
		for i in raw.size():
			var v: Variant = raw[i]
			arr[i] = float(v) if (v is float or v is int) else NAN
		new_series[var_name] = arr
	if new_series.is_empty():
		return false
	_forecast_series = new_series
	_forecast_start_hoy = start_hoy
	_forecast_start_year = start_year
	_forecast_lat = lat
	_forecast_lon = lon
	_forecast_fetched_date = fetched_date if not fetched_date.is_empty() else _today_date_str()
	_forecast_fetched_unix = fetched_unix if fetched_unix > 0 \
		else Time.get_unix_time_from_system()
	return true


## Array index into _forecast_series for the given calendar position, or -1 if
## outside the loaded window. Uses calendar arithmetic — no UTC conversion.
func _forecast_hour_idx(month: int, day: int, hour: float) -> int:
	if _forecast_series.is_empty() or _forecast_start_hoy < 0:
		return -1
	var farr: PackedFloat32Array = _forecast_series.get("cloud_cover", PackedFloat32Array())
	if farr.is_empty():
		return -1
	# The window's entries are consecutive hours, so the request is laid out in
	# the start year's calendar (a window crossing Feb 29 holds that day).
	var start_leap := is_leap_year(_forecast_start_year)
	var req_hoy := day_of_year0(month, day, start_leap) * 24 + clampi(int(hour), 0, 23)
	var offset := req_hoy - _forecast_start_hoy
	# The window spans a few weeks; a large negative offset means the request
	# is in January after a December start. January is before any Feb 29, so
	# only the start year's length matters.
	if offset < -300 * 24:
		offset += (366 if start_leap else 365) * 24
	if offset < 0 or offset >= farr.size():
		return -1
	return offset


## True when a forecast window has been loaded for the current location.
func has_forecast() -> bool:
	return not _forecast_series.is_empty() and _forecast_start_hoy >= 0


## True when the given calendar date falls inside the loaded forecast window.
func is_forecast_date(month: int, day: int) -> bool:
	return _forecast_hour_idx(month, day, 12.0) >= 0


## Hour of year in the COMMON layout: it is compared with _gen_effective_hoy,
## an index into the generated (always 8760-hour) years.
func _calendar_hoy(month: int, day: int, hour: float) -> int:
	return day_of_year0(month, day, false) * 24 + clampi(int(hour), 0, 23)


func _current_calendar_hoy() -> int:
	var d := Time.get_date_dict_from_system()
	var t := Time.get_time_dict_from_system()
	return _calendar_hoy(int(d.month), int(d.day), float(t.hour))


## Real forecast overrides generated/climate data for now … now+FORECAST_OVERRIDE_DAYS.
func _forecast_overrides_generated(month: int, day: int, hour: float) -> bool:
	if _sim_year != _current_calendar_year():
		return false
	if not has_forecast():
		return false
	if _forecast_hour_idx(month, day, hour) < 0:
		return false
	var req := _calendar_hoy(month, day, hour)
	var now := _current_calendar_hoy()
	return req >= now and req < now + FORECAST_OVERRIDE_DAYS * 24


func _recompute_gen_effective_hoy() -> void:
	var now := _current_calendar_hoy()
	if has_forecast():
		_gen_effective_hoy = now + FORECAST_OVERRIDE_DAYS * 24
	else:
		_gen_effective_hoy = now
	var month_start_hoy := _DAYS_BEFORE_MONTH[_gen_start_month - 1] * 24
	_gen_effective_hoy = maxi(_gen_effective_hoy, month_start_hoy)


func _generated_covers_date(month: int, day: int, hour: float) -> bool:
	if not is_generated_year(_sim_year):
		return false
	var yr := _sim_year
	if not _generated.has(yr):
		return false
	var plan: Vector2i = _gen_year_plan.get(yr, Vector2i(1, 12))
	if month < plan.x or month > plan.y:
		return false
	if yr > _gen_start_year:
		return true
	return _calendar_hoy(month, day, hour) >= _gen_effective_hoy


## Returns the data source for a given calendar position: "forecast", "generated",
## "archive", or "ha". Pass ha_active=true when a Home Assistant entity is driving the value.
## Used by the timeline provenance tooltip.
func get_sample_source(month: int, day: int, hour: float, ha_active: bool = false) -> String:
	if ha_active:
		return "ha"
	if _forecast_overrides_generated(month, day, hour):
		return "forecast"
	if _generated_covers_date(month, day, hour):
		var t := _sample_series_dict(_generated[_sim_year], "temperature_2m", month, day, hour)
		if not is_nan(t):
			return "generated"
	if not is_nan(_current_year_sample("temperature_2m", month, day, hour)):
		return "archive_current"
	if _sim_year == _current_calendar_year() and _forecast_hour_idx(month, day, hour) >= 0:
		return "forecast"
	return "archive"


## Parse archive JSON into a series dict without mutating the active dataset.
static func parse_archive_json_to_series(text: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return {}
	var hourly: Dictionary = (parsed as Dictionary).get("hourly", {}) as Dictionary
	if hourly.is_empty():
		return {}
	var new_series: Dictionary = {}
	for var_name in HOURLY_VARS.split(","):
		var raw: Array = hourly.get(var_name, []) as Array
		if raw.is_empty():
			continue
		var arr := PackedFloat32Array()
		arr.resize(raw.size())
		for i in raw.size():
			var v: Variant = raw[i]
			arr[i] = float(v) if (v is float or v is int) else NAN
		new_series[var_name] = arr
	if new_series.is_empty():
		return {}
	return new_series


func parse_archive_json(text: String, lat: float, lon: float, year: int) -> bool:
	var new_series := parse_archive_json_to_series(text)
	if new_series.is_empty():
		return false
	_series = new_series
	_data_lat = lat
	_data_lon = lon
	_data_year = year
	return true


## ---------------------------------------------------------------------------
## Accessors — all return NAN when unavailable
## ---------------------------------------------------------------------------

func has_data() -> bool:
	return not _series.is_empty()


func covers(lat: float, lon: float) -> bool:
	if is_generated_year(_sim_year):
		return not is_nan(_gen_lat) \
			and absf(lat - _gen_lat) <= COVERAGE_EPSILON_DEG \
			and absf(lon - _gen_lon) <= COVERAGE_EPSILON_DEG
	if not has_data():
		return false
	return absf(lat - _data_lat) <= COVERAGE_EPSILON_DEG \
		and absf(lon - _data_lon) <= COVERAGE_EPSILON_DEG


## Linear-interpolated sample of an hourly variable at a calendar position.
## Priority: (1) real forecast for the next FORECAST_OVERRIDE_DAYS when loaded,
## (2) stochastic generated data when it covers the date, (3) archive year series.
func sample(var_name: String, month: int, day: int, hour: float) -> float:
	if _forecast_overrides_generated(month, day, hour):
		var fi := _forecast_hour_idx(month, day, hour)
		if fi >= 0:
			var farr: PackedFloat32Array = _forecast_series.get(var_name, PackedFloat32Array())
			if fi < farr.size():
				var fa := farr[fi]
				var fb := farr[mini(fi + 1, farr.size() - 1)]
				var frac := hour - float(int(hour))
				if is_nan(fa):
					if not is_nan(fb):
						return fb
				elif is_nan(fb):
					return fa
				else:
					return lerpf(fa, fb, frac)
	if _generated_covers_date(month, day, hour):
		var val := _sample_series_dict(_generated[_sim_year], var_name, month, day, hour)
		if not is_nan(val):
			return val
	# The current year's own archive (real 2026 data for a 2026 date) beats both
	# the forecast model's past-days analysis and last year's substitute. NAN
	# (an unpublished recent hour, or a forecast-only var like visibility)
	# falls through.
	var cy := _current_year_sample(var_name, month, day, hour)
	if not is_nan(cy):
		return cy
	# Fall back to archive series (and forecast outside the override window for the
	# current calendar year when generated data does not cover the date).
	if _sim_year == _current_calendar_year() and not _forecast_series.is_empty():
		var fi2 := _forecast_hour_idx(month, day, hour)
		if fi2 >= 0:
			var farr2: PackedFloat32Array = _forecast_series.get(var_name, PackedFloat32Array())
			if fi2 < farr2.size():
				var fa2 := farr2[fi2]
				var fb2 := farr2[mini(fi2 + 1, farr2.size() - 1)]
				var frac2 := hour - float(int(hour))
				if is_nan(fa2):
					if not is_nan(fb2):
						return fb2
				elif is_nan(fb2):
					return fa2
				else:
					return lerpf(fa2, fb2, frac2)
	var arr: PackedFloat32Array = _series.get(var_name, PackedFloat32Array())
	if arr.is_empty():
		return NAN
	return _sample_hourly_array(arr, month, day, hour)


func _sample_series_dict(series: Dictionary, var_name: String, month: int, day: int, hour: float) -> float:
	var arr: PackedFloat32Array = series.get(var_name, PackedFloat32Array())
	if arr.is_empty():
		return NAN
	return _sample_hourly_array(arr, month, day, hour)


## Gregorian leap year.
static func is_leap_year(year: int) -> bool:
	return (year % 4 == 0 and year % 100 != 0) or year % 400 == 0


## True when a FULL hourly series is laid out over a leap year (8784 hours).
## Generated years and stochastic output are always 8760; a partial series
## (the current year's archive) cannot be told by length — pass its year.
static func is_leap_layout(size: int) -> bool:
	return size >= HOURS_LEAP_YEAR


## Zero-based day of year of a calendar date in a common (leap = false) or
## leap (leap = true) layout. Feb 29 in a common layout reads Feb 28 — a
## leap-year date on a common-year dataset repeats the 28th rather than
## jumping ahead to Mar 1.
static func day_of_year0(month: int, day: int, leap: bool) -> int:
	var m := clampi(month, 1, 12)
	var d := clampi(day, 1, 31)
	if m == 2 and d == 29 and not leap:
		d = 28
	var doy := _DAYS_BEFORE_MONTH[m - 1] + d - 1
	if leap and m > 2:
		doy += 1
	return doy


## Fractional hour index of (month, day, hour) into an hourly series of the
## given layout. 2024-04-14 15:00 in a leap layout = (31+29+31+13)*24 + 15.
static func hour_index(month: int, day: int, hour: float, leap: bool) -> float:
	return float(day_of_year0(month, day, leap)) * 24.0 + clampf(hour, 0.0, 23.999)


## A series dict with Feb 29 cut out of every leap-layout array, so it lines
## up hour for hour with the common-year layout the weather generators train
## on and emit (they index by day of a 365-day year).
static func to_common_year(series: Dictionary) -> Dictionary:
	var out := {}
	for k in series:
		var v: Variant = series[k]
		if v is PackedFloat32Array and is_leap_layout((v as PackedFloat32Array).size()):
			var a := v as PackedFloat32Array
			out[k] = a.slice(0, FEB29_HOUR) + a.slice(FEB29_HOUR + 24)
		else:
			out[k] = v
	return out


func _sample_hourly_array(arr: PackedFloat32Array, month: int, day: int, hour: float) -> float:
	var h := hour_index(month, day, hour, is_leap_layout(arr.size()))
	var i0 := clampi(int(h), 0, arr.size() - 1)
	var i1 := mini(i0 + 1, arr.size() - 1)
	var a := arr[i0]
	var b := arr[i1]
	if is_nan(a):
		return b
	if is_nan(b):
		return a
	return lerpf(a, b, h - float(i0))


func wind_speed_ms(month: int, day: int, hour: float) -> float:
	# Open-Meteo wind_speed_10m is km/h by default.
	var kmh := sample("wind_speed_10m", month, day, hour)
	# Site calibration (e.g. open playa vs the Gerlach grid cell); identity
	# unless the map's microclimate profile has a physics wind correction.
	return MicroclimateCorrections.apply("wind_ms", kmh / 3.6) if not is_nan(kmh) else NAN


func wind_gust_ms(month: int, day: int, hour: float) -> float:
	var kmh := sample("windgusts_10m", month, day, hour)
	return MicroclimateCorrections.apply("wind_ms", kmh / 3.6) if not is_nan(kmh) else NAN


func temperature_c(month: int, day: int, hour: float) -> float:
	var t := sample("temperature_2m", month, day, hour)
	if is_generated_year(_sim_year) or _generated_covers_date(month, day, hour):
		return t if is_finite(t) else NAN
	if _sim_year > _current_calendar_year():
		var cps := _get_climate_svc()
		if cps != null and bool(cps.call("has_projection")):
			var dt := float(cps.call("get_temp_delta", _sim_year, month))
			if not is_nan(dt) and not is_nan(t):
				t += dt
	if is_finite(t):
		return clampf(MicroclimateCorrections.apply("t_c", t), -55.0, 55.0)
	return NAN


func cloud_cover_frac(month: int, day: int, hour: float) -> float:
	var pct := sample("cloud_cover", month, day, hour)
	return clampf(MicroclimateCorrections.apply("cloud", pct / 100.0), 0.0, 1.0) if not is_nan(pct) else NAN


func rain_rate_mmh(month: int, day: int, hour: float) -> float:
	var r := sample("precipitation", month, day, hour)
	if is_generated_year(_sim_year) or _generated_covers_date(month, day, hour):
		return r
	if _sim_year > _current_calendar_year():
		var cps := _get_climate_svc()
		if cps != null and bool(cps.call("has_projection")):
			var pf := float(cps.call("get_precip_factor", _sim_year, month))
			if not is_nan(pf) and not is_nan(r):
				r *= pf
	return r


func _get_climate_svc() -> Node:
	if _climate_svc != null and is_instance_valid(_climate_svc):
		return _climate_svc
	_climate_svc = get_node_or_null("/root/ClimateProjectionService")
	return _climate_svc


## Snowfall over the sampled hour, in centimetres of fresh snow (Open-Meteo unit).
## NAN when the dataset lacks snow data (e.g. stochastic-generated years).
func snowfall_cm(month: int, day: int, hour: float) -> float:
	return sample("snowfall", month, day, hour)


## Snow depth on the ground in metres (Open-Meteo `snow_depth`). This is the
## modelled snowpack, so it already integrates accumulation and melt. NAN when
## unavailable; callers should fall back to SeasonModel's degree-day estimate.
func snow_depth_m(month: int, day: int, hour: float) -> float:
	return sample("snow_depth", month, day, hour)


## True when the active dataset carries real snow_depth samples (archive/forecast).
## Generated/synthetic years return false so consumers use the modelled estimate.
func has_snow_data(month: int, day: int, hour: float) -> bool:
	return not is_nan(sample("snow_depth", month, day, hour))


func solar_radiation_wm2(month: int, day: int, hour: float) -> float:
	return sample("shortwave_radiation", month, day, hour)


func diffuse_radiation_wm2(month: int, day: int, hour: float) -> float:
	return sample("diffuse_radiation", month, day, hour)


## Wind direction in degrees (0 = N, 90 = E, 180 = S, 270 = W — meteorological).
func wind_direction_deg(month: int, day: int, hour: float) -> float:
	return sample("wind_direction_10m", month, day, hour)


func _sample_forecast_var(var_name: String, month: int, day: int, hour: float) -> float:
	if not is_forecast_date(month, day):
		return NAN
	var fi := _forecast_hour_idx(month, day, hour)
	if fi < 0:
		return NAN
	var farr: PackedFloat32Array = _forecast_series.get(var_name, PackedFloat32Array())
	if farr.is_empty() or fi >= farr.size():
		return NAN
	# Index by the OFFSET into the window (fi), not by hour-of-year: the window
	# is ~700 entries, so an hour-of-year index clamped every read to its LAST
	# hour (the 80 m / 180 m cloud-drift winds were a constant).
	var i1 := mini(fi + 1, farr.size() - 1)
	var a := farr[fi]
	var b := farr[i1]
	if is_nan(a):
		return b
	if is_nan(b):
		return a
	var hc := clampf(hour, 0.0, 23.999)
	return lerpf(a, b, hc - floorf(hc))


## Low-cloud / cumulus drift: 80 m when forecast has it, else 10 m surface.
func wind_direction_deg_low(month: int, day: int, hour: float, latitude_deg: float = 33.0) -> float:
	var v80 := _sample_forecast_var("wind_direction_80m", month, day, hour)
	if not is_nan(v80):
		return v80
	return wind_direction_deg(month, day, hour)


## High cirrus drift: 180 m in forecast window, else veered surface wind (archive years).
func wind_direction_deg_high(month: int, day: int, hour: float, latitude_deg: float = 33.0) -> float:
	var v180 := _sample_forecast_var("wind_direction_180m", month, day, hour)
	if not is_nan(v180):
		return v180
	var surface := wind_direction_deg(month, day, hour)
	if is_nan(surface):
		return NAN
	var spd := wind_speed_ms(month, day, hour)
	if is_nan(spd):
		spd = 3.0
	return WindMath.veered_from_deg(surface, spd, latitude_deg)


func wind_speed_ms_low(month: int, day: int, hour: float) -> float:
	var kmh := _sample_forecast_var("wind_speed_80m", month, day, hour)
	if not is_nan(kmh):
		return kmh / 3.6
	return wind_speed_ms(month, day, hour)


func wind_speed_ms_high(month: int, day: int, hour: float) -> float:
	var kmh := _sample_forecast_var("wind_speed_180m", month, day, hour)
	if not is_nan(kmh):
		return kmh / 3.6
	var s10 := wind_speed_ms(month, day, hour)
	if is_nan(s10):
		return NAN
	return s10 * 1.35


## Relative humidity as a percent (0–100). NAN when unavailable.
func humidity_pct(month: int, day: int, hour: float) -> float:
	var rh := sample("relative_humidity_2m", month, day, hour)
	return clampf(MicroclimateCorrections.apply("rh", rh), 0.0, 100.0) if is_finite(rh) else rh


## Dew point (°C). Falls back to the Magnus form from T + RH when the series
## has no dew_point_2m (generated years, pre-v5 caches). NAN when neither.
func dew_point_c(month: int, day: int, hour: float) -> float:
	var td := sample("dew_point_2m", month, day, hour)
	if is_finite(td):
		return td
	return dew_point_from_rh(sample("temperature_2m", month, day, hour),
		sample("relative_humidity_2m", month, day, hour))


## Magnus–Tetens dew point (Alduchov & Eskridge 1996: a = 17.625,
## b = 243.04 °C; within ±0.35 °C over −40…50 °C).
static func dew_point_from_rh(t_c: float, rh_pct: float) -> float:
	if not is_finite(t_c) or not is_finite(rh_pct) or rh_pct <= 0.0:
		return NAN
	var g := log(clampf(rh_pct, 0.1, 100.0) / 100.0) + 17.625 * t_c / (243.04 + t_c)
	return 243.04 * g / (17.625 - g)


## Low-level (< ~2 km) cloud fraction 0..1. In ERA5 a radiation fog appears
## HERE, as low cloud at RH 100 % — the cloud sits on the ground.
func low_cloud_frac(month: int, day: int, hour: float) -> float:
	var pct := sample("cloud_cover_low", month, day, hour)
	return clampf(pct / 100.0, 0.0, 1.0) if is_finite(pct) else NAN


## The forecast model's own surface visibility (m). Forecast window only —
## the archive carries none. NAN outside the window.
func model_visibility_m(month: int, day: int, hour: float) -> float:
	if _sim_year != _current_calendar_year():
		return NAN
	return _sample_forecast_var("visibility", month, day, hour)


## ---------------------------------------------------------------------------
## Current-year partial archive
## ---------------------------------------------------------------------------

static func _current_year_cache_path(lat: float, lon: float, year: int) -> String:
	return "%s/om_%s_%.2f_%.2f_%d_partial.json" % [CACHE_DIR, CACHE_VERSION, lat, lon, year]


func _current_year_sample(var_name: String, month: int, day: int, hour: float) -> float:
	if _cy_series.is_empty() or _sim_year != _cy_year:
		return NAN
	var arr: PackedFloat32Array = _cy_series.get(var_name, PackedFloat32Array())
	if arr.is_empty():
		return NAN
	# A partial year cannot be told leap by its length — use its own year.
	var h := hour_index(month, day, hour, is_leap_year(_cy_year))
	var i0 := int(h)
	# Unlike _sample_hourly_array this never clamps past the end: a date beyond
	# what the partial year holds must fall through, not repeat the last hour.
	if i0 >= arr.size():
		return NAN
	var a := arr[i0]
	if is_nan(a):
		return NAN
	var b := arr[mini(i0 + 1, arr.size() - 1)]
	if is_nan(b):
		return a
	return lerpf(a, b, h - float(i0))


## True when the current calendar year's own archive is loaded.
func has_current_year_archive() -> bool:
	return not _cy_series.is_empty()


func ensure_current_year_archive(lat: float, lon: float) -> void:
	var year := _current_calendar_year()
	var here := not is_nan(_cy_lat) and absf(lat - _cy_lat) <= COVERAGE_EPSILON_DEG \
		and absf(lon - _cy_lon) <= COVERAGE_EPSILON_DEG and _cy_year == year
	if not here:
		_cy_series = {}
		_try_load_current_year_cache(lat, lon, year)
		here = not _cy_series.is_empty()
	var stale := not here \
		or Time.get_unix_time_from_system() - _cy_fetched_unix > CURRENT_YEAR_MAX_AGE_SEC
	if stale and not _fetching_cy:
		_request_current_year(lat, lon, year)


func _try_load_current_year_cache(lat: float, lon: float, year: int) -> bool:
	var text := _read_cache_text(_current_year_cache_path(lat, lon, year))
	if text.is_empty():
		return false
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return false
	var d := parsed as Dictionary
	var series := parse_archive_json_to_series(str(d.get("response_text", "")))
	if series.is_empty():
		return false
	_cy_series = series
	_cy_year = year
	_cy_lat = lat
	_cy_lon = lon
	_cy_fetched_unix = int(d.get("fetched_unix", 0))
	return true


func _request_current_year(lat: float, lon: float, year: int) -> void:
	if _http_cy == null or not is_instance_valid(_http_cy):
		_http_cy = HTTPRequest.new()
		_http_cy.timeout = 45.0
		add_child(_http_cy)
		_http_cy.request_completed.connect(_on_current_year_completed)
	var url := "%s?latitude=%.4f&longitude=%.4f&start_date=%d-01-01&end_date=%s&hourly=%s&timezone=auto" \
		% [ARCHIVE_URL, lat, lon, year, _today_date_str(), HOURLY_VARS]
	if _http_cy.request(url) != OK:
		return
	_fetching_cy = true
	set_meta("pending_cy", {"lat": lat, "lon": lon, "year": year})


func _on_current_year_completed(result: int, response_code: int,
		_headers: PackedStringArray, body: PackedByteArray) -> void:
	_fetching_cy = false
	var pending: Dictionary = get_meta("pending_cy", {})
	# A failure stamps the time anyway, so an outage retries once per age
	# window instead of on every 3 s location poll.
	_cy_fetched_unix = Time.get_unix_time_from_system()
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		return
	var text := body.get_string_from_utf8()
	var series := parse_archive_json_to_series(text)
	if series.is_empty():
		return
	_cy_series = series
	_cy_year = int(pending.get("year", 0))
	_cy_lat = float(pending.get("lat", 0.0))
	_cy_lon = float(pending.get("lon", 0.0))
	var f := FileAccess.open(_current_year_cache_path(_cy_lat, _cy_lon, _cy_year), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"fetched_unix": _cy_fetched_unix, "response_text": text}))
		f.close()
	current_year_archive_ready.emit(_cy_lat, _cy_lon, _cy_year)


## Total precipitation (mm) over the 24 hours ending at the given time.
## Returns NAN if no precipitation data is loaded at all.
func rain_24h_mm(month: int, day: int, hour: float) -> float:
	var total := 0.0
	var any_data := false
	var cur_h := int(hour)
	var cur_d := day
	var cur_m := month
	for _i in 24:
		var v := sample("precipitation", cur_m, cur_d, float(cur_h))
		if not is_nan(v):
			total += v
			any_data = true
		cur_h -= 1
		if cur_h < 0:
			cur_h = 23
			cur_d -= 1
			if cur_d < 1:
				cur_m -= 1
				if cur_m < 1:
					cur_m = 12
				cur_d = _days_in_month(cur_m)
	return total if any_data else NAN


## ---------------------------------------------------------------------------
## Stochastic generated future weather
## ---------------------------------------------------------------------------

func is_generated_year(year: int) -> bool:
	return _generated.has(year)


func has_generated() -> bool:
	return not _generated.is_empty()


func generated_years() -> Array[int]:
	var out: Array[int] = []
	for yr_v in _generated.keys():
		out.append(int(yr_v))
	out.sort()
	return out


func is_generating() -> bool:
	return _gen_active


func clear_generated() -> void:
	_generated.clear()
	_generated_yearbook.clear()
	_gen_years_done.clear()
	_gen_years_queue.clear()
	_gen_year_plan.clear()
	_gen_active = false
	_gen_working.clear()


## Drop cached generated yearbook entries (all years, or a subset).
func invalidate_generated_yearbook(years: Array = []) -> void:
	if years.is_empty():
		_generated_yearbook.clear()
		return
	for yr_v in years:
		_generated_yearbook.erase(int(yr_v))


func has_generated_yearbook(year: int) -> bool:
	return _generated_yearbook.has(year)


func get_generated_yearbook(year: int) -> Dictionary:
	return _generated_yearbook.get(year, {}) as Dictionary


## Count record-breaking days for one month using hourly generated weather.
func count_generated_record_breaks_for_month(year: int, month: int) -> Dictionary:
	var empty := {"highs": 0, "lows": 0, "precip": 0}
	if not has_records() or not _generated.has(year):
		return empty
	var series: Dictionary = _generated[year] as Dictionary
	var temp: PackedFloat32Array = series.get("temperature_2m", PackedFloat32Array())
	if temp.is_empty():
		return empty
	var precip: PackedFloat32Array = series.get("precipitation", PackedFloat32Array())
	var get_rec_fn := func(m: int, d: int) -> Dictionary:
		return get_records(m, d)
	var covered_fn := func(m: int, d: int) -> bool:
		return _generated_day_fully_covered(year, m, d)
	return RecordBreakCounter.count_month_from_hourly(
		temp, precip, month, get_rec_fn, covered_fn)


## Sum 12 months of generated record-break counts for one calendar year.
func compute_generated_yearbook_for_year(year: int) -> Dictionary:
	var out := {"highs": 0, "lows": 0, "precip": 0, "source": "generated"}
	if not has_records() or not _generated.has(year):
		return out
	for month in range(1, 13):
		RecordBreakCounter.accumulate(out, count_generated_record_breaks_for_month(year, month))
	return out


func store_generated_yearbook(year: int, entry: Dictionary) -> void:
	var stored := entry.duplicate()
	stored["source"] = "generated"
	_generated_yearbook[year] = stored
	# TODO(weather-gen): persist generated yearbook to user:// alongside gen cache;
	# rebuild automatically when records_ready arrives after generation_complete.


## True when every hour of [param day] lies inside the generated span for [param year].
func _generated_day_fully_covered(year: int, month: int, day: int) -> bool:
	if not _generated.has(year):
		return false
	var plan: Vector2i = _gen_year_plan.get(year, Vector2i(1, 12))
	if month < plan.x or month > plan.y:
		return false
	if year > _gen_start_year:
		return true
	# First tranche year: only days at/after the forecast handoff.
	return _calendar_hoy(month, day, 0) >= _gen_effective_hoy


func training_years() -> Array[int]:
	var end_year := effective_year(_current_calendar_year())
	var out: Array[int] = []
	for i in range(TRAINING_YEAR_COUNT):
		out.append(end_year - TRAINING_YEAR_COUNT + 1 + i)
	return out


func is_fetching_training() -> bool:
	return _fetching_training


func is_loading_training() -> bool:
	return _training_load_active


func has_pending_generation() -> bool:
	return not _pending_generation.is_empty()


func has_training_archives(lat: float, lon: float) -> bool:
	if is_nan(_training_lat) or is_nan(_training_lon):
		return false
	if absf(lat - _training_lat) > COVERAGE_EPSILON_DEG \
			or absf(lon - _training_lon) > COVERAGE_EPSILON_DEG:
		return false
	for yr in training_years():
		if not _training_series.has(yr):
			return false
	return true


func request_training_archives(lat: float, lon: float, force_refresh: bool = false) -> void:
	var loc_changed := is_nan(_training_lat) \
		or absf(lat - _training_lat) > COVERAGE_EPSILON_DEG \
		or absf(lon - _training_lon) > COVERAGE_EPSILON_DEG

	if force_refresh or loc_changed:
		_training_series.clear()
		_training_load_active = false
		_training_load_queue.clear()
		_training_fetch_queue.clear()

	if not force_refresh and not loc_changed and has_training_archives(lat, lon):
		training_archives_ready.emit(lat, lon)
		_try_start_pending_generation()
		return

	_training_lat = lat
	_training_lon = lon
	_training_load_queue.clear()
	for yr in training_years():
		if force_refresh or not _training_series.has(yr):
			_training_load_queue.append(yr)
	_training_load_active = not _training_load_queue.is_empty()
	if _training_load_active:
		training_archives_progress.emit(_training_series.size(), TRAINING_YEAR_COUNT)
		return
	# All training years already resident — still emit so UI can show completion.
	training_archives_progress.emit(_training_series.size(), TRAINING_YEAR_COUNT)
	training_archives_ready.emit(lat, lon)
	_try_start_pending_generation()


## Load one training archive year per call (from disk cache or network queue).
## Returns true when the disk-load phase is finished (network fetch may continue).
func training_load_step() -> bool:
	if not _training_load_active or _training_load_queue.is_empty():
		_training_load_active = false
		if _training_fetch_queue.is_empty() and has_training_archives(_training_lat, _training_lon):
			training_archives_ready.emit(_training_lat, _training_lon)
			_try_start_pending_generation()
		elif not _training_fetch_queue.is_empty() and not _fetching_training:
			_dispatch_training_fetch()
		return true
	var yr := _training_load_queue[0]
	_training_load_queue.remove_at(0)
	var cached := _read_archive_series_from_cache(_training_lat, _training_lon, yr)
	if cached.is_empty():
		if not _training_fetch_queue.has(yr):
			_training_fetch_queue.append(yr)
	else:
		_training_series[yr] = cached
	training_archives_progress.emit(_training_series.size(), TRAINING_YEAR_COUNT)
	if _training_load_queue.is_empty():
		_training_load_active = false
		if _training_fetch_queue.is_empty():
			training_archives_ready.emit(_training_lat, _training_lon)
			_try_start_pending_generation()
		else:
			_dispatch_training_fetch()
	return _training_load_queue.is_empty()


func _read_archive_series_from_cache(lat: float, lon: float, year: int) -> Dictionary:
	var text := _read_cache_text(_cache_path(lat, lon, year))
	if text.is_empty():
		return {}
	return parse_archive_json_to_series(text)


func _ensure_http_training() -> void:
	if _http_training != null and is_instance_valid(_http_training):
		return
	_http_training = HTTPRequest.new()
	_http_training.timeout = 120.0
	add_child(_http_training)
	_http_training.request_completed.connect(_on_training_request_completed)


func _dispatch_training_fetch() -> void:
	if _fetching_training or _training_fetch_queue.is_empty():
		return
	_ensure_http_training()
	var year := _training_fetch_queue[0]
	var url := "%s?latitude=%.4f&longitude=%.4f&start_date=%d-01-01&end_date=%d-12-31&hourly=%s&timezone=auto" \
		% [ARCHIVE_URL, _training_lat, _training_lon, year, year, HOURLY_VARS]
	var err := _http_training.request(url)
	if err != OK:
		training_fetch_failed.emit("HTTPRequest error %d" % err)
		return
	_fetching_training = true
	set_meta("pending_training", {"lat": _training_lat, "lon": _training_lon, "year": year})


func _on_training_request_completed(result: int, response_code: int,
		_headers: PackedStringArray, body: PackedByteArray) -> void:
	_fetching_training = false
	var pending: Dictionary = get_meta("pending_training", {})
	var lat := float(pending.get("lat", 0.0))
	var lon := float(pending.get("lon", 0.0))
	var year := int(pending.get("year", 0))
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		training_fetch_failed.emit("training fetch failed (result %d, HTTP %d)" % [result, response_code])
		_training_fetch_queue.clear()
		_pending_generation.clear()
		return
	var text := body.get_string_from_utf8()
	var series := parse_archive_json_to_series(text)
	if series.is_empty():
		training_fetch_failed.emit("unparseable training archive response")
		_training_fetch_queue.clear()
		_pending_generation.clear()
		return
	var f := FileAccess.open(_cache_path(lat, lon, year), FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()
	_training_series[year] = series
	if not _training_fetch_queue.is_empty() and _training_fetch_queue[0] == year:
		_training_fetch_queue.remove_at(0)
	training_archives_progress.emit(_training_series.size(), TRAINING_YEAR_COUNT)
	if _training_fetch_queue.is_empty():
		training_archives_ready.emit(lat, lon)
		_try_start_pending_generation()
	else:
		_dispatch_training_fetch()


func _try_start_pending_generation() -> void:
	if _pending_generation.is_empty():
		return
	if not has_training_archives(_training_lat, _training_lon):
		return
	var p := _pending_generation.duplicate()
	_pending_generation.clear()
	var plan := _compute_gen_year_plan(
		int(Time.get_date_dict_from_system().year),
		clampi(int(Time.get_date_dict_from_system().month), 1, 12),
		int(p.get("num_years", 1)),
	)
	_gen_force_refresh = bool(p.get("force_refresh", true))
	_begin_generation_impl(
		int(p.get("seed", 0)),
		int(p.get("num_years", 1)),
		float(p.get("lat", 0.0)),
		float(p.get("lon", 0.0)),
		int(p.get("scenario", -1)),
		plan,
		int(p.get("engine_kind", _default_engine_kind)),
	)


## Begin incremental generation. When force_refresh is true (default), deletes
## any on-disk generated cache for this location/seed/scenario and rebuilds
## training + weather from scratch with progress signals.
func begin_generation(seed: int, num_years: int, lat: float, lon: float, scenario: int = -1,
		force_refresh: bool = true, engine_kind: int = -1) -> bool:
	if engine_kind < 0:
		engine_kind = _default_engine_kind
	engine_kind = clampi(engine_kind, 0, GenEngine.size() - 1)
	_gen_force_refresh = force_refresh
	var today := Time.get_date_dict_from_system()
	var start_year := int(today.year)
	var start_month := clampi(int(today.month), 1, 12)
	var plan := _compute_gen_year_plan(start_year, start_month, num_years)

	if force_refresh:
		_generated.clear()
		invalidate_generated_yearbook()
		_purge_generated_caches(lat, lon, seed, scenario, engine_kind, plan)
		_training_series.clear()
		_training_lat = NAN

	request_training_archives(lat, lon, force_refresh)

	if is_loading_training() or is_fetching_training() or not has_training_archives(lat, lon):
		_pending_generation = {
			"seed": seed,
			"num_years": num_years,
			"lat": lat,
			"lon": lon,
			"scenario": scenario,
			"force_refresh": force_refresh,
			"engine_kind": engine_kind,
		}
		return false
	return _begin_generation_impl(seed, num_years, lat, lon, scenario, plan, engine_kind)


func _compute_gen_year_plan(start_year: int, start_month: int, num_years: int) -> Dictionary:
	var plan: Dictionary = {}
	plan[start_year] = Vector2i(start_month, 12)
	for i in range(1, maxi(1, num_years)):
		var yr := start_year + i
		plan[yr] = Vector2i(1, 12)
	return plan


func _purge_generated_caches(lat: float, lon: float, seed: int, scenario: int,
		engine_kind: int, plan: Dictionary) -> void:
	for yr_v in plan.keys():
		_delete_cache_file(_gen_cache_path_for(int(yr_v), lat, lon, seed, scenario, engine_kind))
	# Also remove stale blobs for the same site/seed/scenario/engine outside this plan.
	var prefix := "gen_%s_%s_%.2f_%.2f_%d_%d_" \
		% [GEN_CACHE_VERSION, _engine_tag(engine_kind), lat, lon, seed, scenario]
	var abs_dir := ProjectSettings.globalize_path(CACHE_DIR)
	if abs_dir.is_empty():
		return
	var dir := DirAccess.open(abs_dir)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not dir.current_is_dir() and entry.begins_with(prefix) and entry.ends_with(".json"):
			_delete_cache_file("%s/%s" % [CACHE_DIR, entry])
		entry = dir.get_next()
	dir.list_dir_end()


func _begin_generation_impl(seed: int, num_years: int, lat: float, lon: float, scenario: int,
		plan: Dictionary = {}, engine_kind: int = -1) -> bool:
	if engine_kind < 0:
		engine_kind = _default_engine_kind
	_gen_engine_kind = clampi(engine_kind, 0, GenEngine.size() - 1)
	generation_training_started.emit()
	_gen_engine = _make_engine(_gen_engine_kind)
	# The engines learn by day of a 365-day year: drop Feb 29 from leap
	# archives or every later day of those years trains on the next one.
	var common := {}
	for yr in _training_series:
		common[yr] = to_common_year(_training_series[yr] as Dictionary)
	if not _gen_engine.train_from_multi_series(common):
		push_warning("WeatherService: failed to train %s engine from %d archive years" \
			% [_engine_tag(_gen_engine_kind), _training_series.size()])
		return false
	var today := Time.get_date_dict_from_system()
	_gen_seed = seed
	_gen_scenario = scenario
	_gen_lat = lat
	_gen_lon = lon
	_gen_engine.set_location(lat, lon)
	_gen_start_year = int(today.year)
	_gen_start_month = clampi(int(today.month), 1, 12)
	_gen_num_years = maxi(1, num_years)
	_recompute_gen_effective_hoy()
	_gen_year_plan = plan if not plan.is_empty() else _compute_gen_year_plan(
		_gen_start_year, _gen_start_month, _gen_num_years)
	_gen_years_done.clear()
	_gen_years_queue.clear()
	_gen_total_months = 0
	for yr_v in _gen_year_plan.keys():
		var span: Vector2i = _gen_year_plan[yr_v]
		_gen_total_months += span.y - span.x + 1
	_gen_months_done = 0
	for yr_v in _gen_year_plan.keys():
		var yr := int(yr_v)
		if _gen_force_refresh:
			_generated.erase(yr)
		elif _try_load_generated_cache(yr):
			_gen_years_done.append(yr)
			continue
		_gen_years_queue.append(yr)
	_gen_force_refresh = false
	if _gen_years_queue.is_empty():
		_gen_active = false
		_finish_generation()
		return true
	_gen_cur_year = _gen_years_queue[0]
	var year_span: Vector2i = _gen_year_plan[_gen_cur_year]
	_gen_cur_month = year_span.x
	_gen_working.clear()
	_configure_gen_engine_for_year(_gen_cur_year)
	_gen_engine.begin_year(_gen_seed, _gen_cur_year)
	_gen_active = true
	generation_progress.emit(_gen_cur_year, _gen_cur_month, 0.0)
	return true


## Generate one calendar month; call once per frame from UI.
func generation_step() -> Dictionary:
	if not _gen_active:
		return {"done": true, "year": 0, "month": 0, "frac": 1.0}
	if _gen_years_queue.is_empty():
		_gen_active = false
		_finish_generation()
		return {"done": true, "year": _gen_start_year, "month": 12, "frac": 1.0}

	var yr := _gen_cur_year
	var mo := _gen_cur_month
	var plan: Vector2i = _gen_year_plan.get(yr, Vector2i(1, 12))
	var cps := _get_climate_svc()
	var delta_fn := func(m: int) -> float:
		if cps != null and bool(cps.call("has_projection")):
			return float(cps.call("get_temp_delta", yr, m))
		return 0.0
	var precip_fn := func(m: int) -> float:
		if cps != null and bool(cps.call("has_projection")):
			return float(cps.call("get_precip_factor", yr, m))
		return 1.0

	_gen_engine.generate_month(mo, _gen_working, delta_fn, precip_fn)
	_gen_cur_month += 1
	_gen_months_done += 1
	var total_frac := float(_gen_months_done) / float(maxi(_gen_total_months, 1))
	generation_progress.emit(yr, mo, total_frac)

	if _gen_cur_month > plan.y:
		_commit_generated_year(yr)
		_gen_years_queue.erase(yr)
		_gen_years_done.append(yr)
		_gen_working.clear()
		if _gen_years_queue.is_empty():
			_gen_active = false
			_finish_generation()
			return {"done": true, "year": yr, "month": plan.y, "frac": 1.0}
		_gen_cur_year = _gen_years_queue[0]
		var next_plan: Vector2i = _gen_year_plan[_gen_cur_year]
		_gen_cur_month = next_plan.x
		_configure_gen_engine_for_year(_gen_cur_year)
		_gen_engine.begin_year(_gen_seed, _gen_cur_year)

	return {"done": false, "year": yr, "month": mo, "frac": total_frac}


func _configure_gen_engine_for_year(year: int) -> void:
	if _gen_engine == null:
		return
	if year == _gen_start_year:
		_gen_engine.set_effective_hoy(_gen_effective_hoy)
	else:
		_gen_engine.set_effective_hoy(0)


func _commit_generated_year(year: int) -> void:
	_generated[year] = _gen_working.duplicate(true)
	_write_generated_cache(year, _gen_working)
	# Yearbook is rebuilt incrementally by the record book panel on generation_complete.
	_generated_yearbook.erase(year)


func _finish_generation() -> void:
	var years: Array = []
	for yr in _gen_years_done:
		years.append(yr)
	years.sort()
	generation_complete.emit(years)
	_resolve_main()
	if _main_node != null:
		_main_node.set("year", _gen_start_year)
	_sim_year = _gen_start_year


func _try_load_generated_cache(year: int) -> bool:
	var path := _gen_cache_path(year)
	var text := _read_cache_text(path)
	if text.is_empty():
		return false
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return false
	var d := parsed as Dictionary
	if int(d.get("seed", -1)) != _gen_seed:
		return false
	if int(d.get("scenario", -1)) != _gen_scenario:
		return false
	if int(d.get("engine", GenEngine.PARAMETRIC)) != _gen_engine_kind:
		return false
	if year == _gen_start_year:
		if int(d.get("start_month", 1)) != _gen_start_month:
			return false
		if int(d.get("effective_hoy", -1)) != _gen_effective_hoy:
			return false
	var series_v: Variant = d.get("series", null)
	if not (series_v is Dictionary):
		return false
	_generated[year] = StochasticWeatherGenerator.series_from_dict(series_v as Dictionary)
	return true


func _write_generated_cache(year: int, series: Dictionary) -> void:
	var payload := {
		"seed": _gen_seed,
		"scenario": _gen_scenario,
		"engine": _gen_engine_kind,
		"lat": _gen_lat,
		"lon": _gen_lon,
		"year": year,
		"start_month": _gen_start_month if year == _gen_start_year else 1,
		"effective_hoy": _gen_effective_hoy if year == _gen_start_year else 0,
		"series": StochasticWeatherGenerator.series_to_dict(series),
	}
	var f := FileAccess.open(_gen_cache_path(year), FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(payload))
	f.close()


func _gen_cache_path(year: int) -> String:
	return _gen_cache_path_for(year, _gen_lat, _gen_lon, _gen_seed, _gen_scenario, _gen_engine_kind)


static func _gen_cache_path_for(year: int, lat: float, lon: float, seed: int, scenario: int,
		engine_kind: int = GenEngine.PARAMETRIC) -> String:
	return "%s/gen_%s_%s_%.2f_%.2f_%d_%d_%d.json" \
		% [CACHE_DIR, GEN_CACHE_VERSION, _engine_tag(engine_kind), lat, lon, seed, scenario, year]


static func _days_in_month(month: int) -> int:
	var days: Array[int] = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
	return days[clampi(month, 1, 12) - 1]


## ---------------------------------------------------------------------------
## Phase 4: Temperature record book (1940-present daily max/min)
## ---------------------------------------------------------------------------

func request_records(lat: float, lon: float) -> void:
	if _fetching_records:
		return
	var cache_path := _records_cache_path(lat, lon)
	var text := _read_cache_text(cache_path)
	if not text.is_empty():
		if _load_records_cache(text, lat, lon):
			records_ready.emit.call_deferred(lat, lon)
			return
	_delete_cache_file(cache_path)
	_ensure_http_records()
	var end_year := effective_year(_current_calendar_year())
	var url := "%s?latitude=%.4f&longitude=%.4f&start_date=1940-01-01&end_date=%d-12-31&daily=%s&timezone=auto" \
		% [ARCHIVE_URL, lat, lon, end_year, RECORDS_DAILY_VARS]
	var err := _http_records.request(url)
	if err != OK:
		_fetching_records = false
		return
	_fetching_records = true
	set_meta("pending_records", {"lat": lat, "lon": lon})


func _on_records_request_completed(result: int, response_code: int,
		_headers: PackedStringArray, body: PackedByteArray) -> void:
	_fetching_records = false
	var pending: Dictionary = get_meta("pending_records", {})
	var lat := float(pending.get("lat", 0.0))
	var lon := float(pending.get("lon", 0.0))
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		push_warning("WeatherService: records fetch failed (result %d, HTTP %d)" % [result, response_code])
		return
	var text := body.get_string_from_utf8()
	if not parse_records_json(text, lat, lon):
		push_warning("WeatherService: unparseable records response")
		return
	# Persist cache.
	var cache_data := {
		"fetch_year": _current_calendar_year(),
		"records": _records,
	}
	var f := FileAccess.open(_records_cache_path(lat, lon), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(cache_data))
		f.close()
	records_ready.emit(lat, lon)


## Build the per-day-of-year record book from an Open-Meteo daily response.
## Public and side-effect-contained so tests can feed canned JSON.
func parse_records_json(text: String, lat: float, lon: float) -> bool:
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return false
	var daily: Dictionary = (parsed as Dictionary).get("daily", {}) as Dictionary
	if daily.is_empty():
		return false
	var times:  Array = daily.get("time", []) as Array
	var highs:  Array = daily.get("temperature_2m_max", []) as Array
	var lows:   Array = daily.get("temperature_2m_min", []) as Array
	var precips: Array = daily.get("precipitation_sum", []) as Array
	if times.is_empty() or highs.is_empty():
		return false
	var new_records: Dictionary = {}
	for i in times.size():
		var date_str := str(times[i])  # "YYYY-MM-DD"
		if date_str.length() < 10:
			continue
		var key  := date_str.substr(5, 5)   # "MM-DD"
		var year := int(date_str.substr(0, 4))
		var high_v:  Variant = highs[i]   if i < highs.size()   else null
		var low_v:   Variant = lows[i]    if i < lows.size()    else null
		var prec_v:  Variant = precips[i] if i < precips.size() else null
		var high_f  := float(high_v)  if (high_v  is float or high_v  is int) else NAN
		var low_f   := float(low_v)   if (low_v   is float or low_v   is int) else NAN
		var prec_f  := float(prec_v)  if (prec_v  is float or prec_v  is int) else NAN
		var existing: Dictionary = new_records.get(key, {}) as Dictionary
		if not is_nan(high_f):
			if existing.is_empty() or high_f > float(existing.get("high", -1e9)):
				existing["high"]      = high_f
				existing["high_year"] = year
		if not is_nan(low_f):
			if existing.is_empty() or low_f < float(existing.get("low", 1e9)):
				existing["low"]      = low_f
				existing["low_year"] = year
		if not is_nan(prec_f) and prec_f > 0.0:
			if existing.is_empty() or prec_f > float(existing.get("precip", -1.0)):
				existing["precip"]      = prec_f
				existing["precip_year"] = year
		if not existing.is_empty():
			new_records[key] = existing
	if new_records.is_empty():
		return false
	_records = new_records
	_records_lat = lat
	_records_lon = lon
	_records_fetch_year = _current_calendar_year()
	return true


func _load_records_cache(text: String, lat: float, lon: float) -> bool:
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return false
	var d := parsed as Dictionary
	if int(d.get("fetch_year", 0)) < _current_calendar_year():
		return false  # stale — current year still accumulating
	var recs: Variant = d.get("records", null)
	if not (recs is Dictionary) or (recs as Dictionary).is_empty():
		return false
	_records = recs as Dictionary
	_records_lat = lat
	_records_lon = lon
	_records_fetch_year = int(d.get("fetch_year", 0))
	return true


## Returns { "high": float, "high_year": int, "low": float, "low_year": int,
##           "precip": float, "precip_year": int }
## for the given calendar day, or an empty Dictionary if records are not loaded.
func get_records(month: int, day: int) -> Dictionary:
	var key := "%02d-%02d" % [month, day]
	return _records.get(key, {}) as Dictionary


func has_records() -> bool:
	return not _records.is_empty()


## Aggregate how many all-time records each year holds from the loaded record book.
## Returns { year(int): { "highs": int, "lows": int, "precip": int } }.
## Zero-cost (no fetch); call after has_records() == true.
func compute_yearbook() -> Dictionary:
	var book: Dictionary = {}
	for md_key in _records.keys():
		var rec: Dictionary = _records[md_key] as Dictionary
		var hy := int(rec.get("high_year",  0))
		var ly := int(rec.get("low_year",   0))
		var py := int(rec.get("precip_year", 0))
		if hy > 0:
			if not book.has(hy):
				book[hy] = {"highs": 0, "lows": 0, "precip": 0}
			book[hy]["highs"] = int(book[hy]["highs"]) + 1
		if ly > 0:
			if not book.has(ly):
				book[ly] = {"highs": 0, "lows": 0, "precip": 0}
			book[ly]["lows"] = int(book[ly]["lows"]) + 1
		if py > 0:
			if not book.has(py):
				book[py] = {"highs": 0, "lows": 0, "precip": 0}
			book[py]["precip"] = int(book[py]["precip"]) + 1
	return book


## Returns sorted MM-DD string lists of the records held by the given year.
## { "highs": Array[String], "lows": Array[String], "precip": Array[String] }
func get_record_dates_for_year(year: int) -> Dictionary:
	var result: Dictionary = { "highs": [], "lows": [], "precip": [] }
	for md_key in _records.keys():
		var rec: Dictionary = _records[md_key] as Dictionary
		if int(rec.get("high_year",  0)) == year:
			result["highs"].append(str(md_key))
		if int(rec.get("low_year",   0)) == year:
			result["lows"].append(str(md_key))
		if int(rec.get("precip_year", 0)) == year:
			result["precip"].append(str(md_key))
	result["highs"].sort()
	result["lows"].sort()
	result["precip"].sort()
	return result


static func _records_cache_path(lat: float, lon: float) -> String:
	return "%s/records_%s_%.4f_%.4f.json" % [CACHE_DIR, RECORDS_CACHE_VERSION, lat, lon]


## 12 monthly precipitation totals normalized to mean 1.0 — drop-in flow
## multipliers for HydroSource/HydroConfig. Empty array when unavailable.
## Total precipitation (mm) summed per calendar month over the cached year, or []
## when no precipitation series is loaded (offline).
func monthly_precip_mm() -> Array[float]:
	var arr: PackedFloat32Array = _series.get("precipitation", PackedFloat32Array())
	if arr.is_empty():
		return []
	var sums: Array[float] = []
	sums.resize(12)
	sums.fill(0.0)
	var leap := is_leap_layout(arr.size())
	for m in 12:
		var start := day_of_year0(m + 1, 1, leap) * 24
		var end := (day_of_year0(m + 2, 1, leap) * 24) if m < 11 else arr.size()
		end = mini(end, arr.size())
		for i in range(start, end):
			var v := arr[i]
			if not is_nan(v):
				sums[m] += v
	return sums


func monthly_precip_multipliers() -> Array[float]:
	var sums := monthly_precip_mm()
	if sums.is_empty():
		return []
	var total := 0.0
	for s in sums:
		total += s
	if total <= 0.0:
		return []
	var mean := total / 12.0
	var mults: Array[float] = []
	for s in sums:
		mults.append(s / mean)
	return mults
