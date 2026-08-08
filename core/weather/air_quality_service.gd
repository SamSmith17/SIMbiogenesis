extends Node

## AirQualityService — hourly aerosol and air-quality data for the current site.
##
## API: https://air-quality-api.open-meteo.com/v1/air-quality — no key required.
## Data source: Copernicus Atmosphere Monitoring Service (CAMS). ATTRIBUTION IS
## MANDATORY: "CAMS ENSEMBLE data provider" plus a reference to Open-Meteo. See
## CREDITS.md.
##
## Mirrors WeatherService's FORECAST channel (request_forecast / parse_forecast_json
## / _forecast_hour_idx) rather than its archive channel, because the air-quality
## endpoint has the same past_days/forecast_days shape. Two deliberate divergences:
##
##  1. INDEXED BY ABSOLUTE HOURS, not hour-of-year. WeatherService's forecast
##     window is ~21 days, so its "large negative offset means the previous year"
##     heuristic is safe. This window is up to 99 days, where that heuristic
##     silently fails across a New Year boundary — a request in early January
##     against an October-start window lands at roughly -283 days, which is not
##     negative enough to trigger the wrap and so reads as "outside the window".
##     Converting both ends through CelestialClock is exact and needs no
##     heuristic, and the director works in absolute hours anyway.
##
##  2. PER-VARIABLE fallback. Open-Meteo serves ~11 km CAMS-Europe inside Europe
##     and ~40 km CAMS-global elsewhere, and they do not carry the same fields —
##     `dust` in particular is a global-model field. A column that comes back
##     entirely null means "unsupported here", not "zero", so it is dropped
##     rather than stored as a wall of zeroes that would read as clean air.
##
## COVERAGE IS NARROW AND THAT IS THE POINT: past_days maxes at 92 and
## forecast_days at 7, and the global archive only reaches back to August 2022.
## Anything outside that window returns NAN and the director falls back to the
## alert-span and climatology layers. Callers must treat NAN as "no data", never
## as "clean".
##
## Offline behaviour: every accessor returns NAN; nothing blocks or errors.

signal air_quality_ready(latitude: float, longitude: float)
signal air_quality_failed(reason: String)

const AQ_URL := "https://air-quality-api.open-meteo.com/v1/air-quality"

## Requested hourly variables. `dust` and `aerosol_optical_depth` are the two
## this feature exists for; pm2_5/pm10 drive visibility and the health channel;
## us_aqi is carried so the HUD can show the same number a real air-quality site
## would.
const AQ_VARS := "pm10,pm2_5,dust,aerosol_optical_depth,us_aqi,carbon_monoxide"

## API maxima. Exceeding either is a hard 400 from Open-Meteo.
const PAST_DAYS := 92
const FORECAST_DAYS := 7

const CACHE_DIR := "user://weather_cache"
const MAX_CACHE_BYTES := 25 * 1024 * 1024
## Bump when AQ_VARS or the cache envelope changes so old blobs retire.
## v1 = initial (pm10, pm2_5, dust, aerosol_optical_depth, us_aqi, carbon_monoxide).
const CACHE_VERSION := "v1"

## Same location tolerance WeatherService uses (~5.5 km).
const COVERAGE_EPSILON_DEG := 0.05
const MAX_AGE_SEC := 6 * 3600
const RETRY_BACKOFF := 4.0
const MAX_RETRIES := 3

var _http: HTTPRequest = null
var _fetching := false
var _retries := 0
var _pending_url := ""

## var_name -> PackedFloat32Array, hourly, aligned to _start_abs.
var _series: Dictionary = {}
## Absolute hours (CelestialClock epoch) of _series[*][0].
var _start_abs := NAN
var _lat := NAN
var _lon := NAN
var _fetched_date := ""
var _fetched_unix := 0.0

var _main_node: Node = null
var _poll_acc := 0.0
const POLL_INTERVAL := 5.0


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE_DIR))
	_ensure_http()
	set_process(true)


## Lazily created so the service works when driven before _ready (e.g. from a
## SceneTree --script context) — the WeatherService/ElevationService pattern.
func _ensure_http() -> void:
	if _http != null and is_instance_valid(_http):
		return
	_http = HTTPRequest.new()
	_http.timeout = 30.0
	add_child(_http)
	_http.request_completed.connect(_on_completed)


func _process(delta: float) -> void:
	_poll_acc += delta
	if _poll_acc < POLL_INTERVAL:
		return
	_poll_acc = 0.0
	_resolve_main()
	if _main_node == null or not is_instance_valid(_main_node):
		return
	var lat: Variant = _main_node.get("latitude")
	var lon: Variant = _main_node.get("longitude")
	if lat == null or lon == null:
		return
	ensure_fresh(float(lat), float(lon))


## --- public API --------------------------------------------------------------

func has_data() -> bool:
	return not _series.is_empty() and is_finite(_start_abs)


func covers(lat: float, lon: float) -> bool:
	if not has_data():
		return false
	return not _location_mismatch(lat, lon)


## True when this instant falls inside the loaded window. Callers should check
## this rather than testing a sample for NAN, because a single null hour inside
## a valid window is a data gap, not a coverage gap.
func covers_time(abs_hours: float) -> bool:
	return _index_for(abs_hours) >= 0


func window_start_abs() -> float:
	return _start_abs


func window_end_abs() -> float:
	if not has_data():
		return NAN
	return _start_abs + float(_longest_series_size())


func ensure_fresh(lat: float, lon: float, force: bool = false) -> void:
	if not has_data() or _location_mismatch(lat, lon):
		_try_load_cache(lat, lon)
	if force or _is_stale(lat, lon):
		if not _fetching:
			request_air_quality(lat, lon)


func request_air_quality(lat: float, lon: float) -> void:
	if _fetching:
		return
	_ensure_http()
	var url := "%s?latitude=%.4f&longitude=%.4f&hourly=%s&past_days=%d&forecast_days=%d&timezone=auto" \
		% [AQ_URL, lat, lon, AQ_VARS, PAST_DAYS, FORECAST_DAYS]
	_pending_url = url
	_retries = 0
	var err := _http.request(url)
	if err != OK:
		# Deferred so a consumer that connects right after this call still sees
		# the notification — the project-wide rule for this pattern.
		air_quality_failed.emit.call_deferred("HTTPRequest error %d" % err)
		return
	_fetching = true
	set_meta("pending", {"lat": lat, "lon": lon})


## Value of `var_name` at an absolute-hours instant, linearly interpolated.
## NAN when out of window, unknown, or genuinely missing.
func sample_at_abs(var_name: String, abs_hours: float) -> float:
	if not has_data() or not is_finite(abs_hours):
		return NAN
	var arr: PackedFloat32Array = _series.get(var_name, PackedFloat32Array())
	if arr.is_empty():
		return NAN
	var pos := abs_hours - _start_abs
	if pos < 0.0 or pos >= float(arr.size()):
		return NAN
	var i0 := int(floor(pos))
	var frac := pos - float(i0)
	var a := arr[i0]
	var i1 := mini(i0 + 1, arr.size() - 1)
	var b := arr[i1]
	# CAMS global is natively 3-hourly, so isolated nulls are normal; take
	# whichever endpoint is real rather than propagating the gap.
	if is_nan(a):
		return b
	if is_nan(b):
		return a
	return lerpf(a, b, frac)


func pm25_ugm3(abs_hours: float) -> float:
	return sample_at_abs("pm2_5", abs_hours)


func pm10_ugm3(abs_hours: float) -> float:
	return sample_at_abs("pm10", abs_hours)


func dust_ugm3(abs_hours: float) -> float:
	return sample_at_abs("dust", abs_hours)


func aerosol_optical_depth(abs_hours: float) -> float:
	return sample_at_abs("aerosol_optical_depth", abs_hours)


func us_aqi(abs_hours: float) -> float:
	return sample_at_abs("us_aqi", abs_hours)


## Which variables actually came back for this site — the per-variable fallback
## in action. A site outside the dust model's domain simply will not list it.
func available_vars() -> Array[String]:
	var out: Array[String] = []
	for k: String in _series.keys():
		out.append(k)
	out.sort()
	return out


func reset_session() -> void:
	if _http != null and is_instance_valid(_http):
		_http.cancel_request()
	_fetching = false
	_pending_url = ""


## --- parsing -----------------------------------------------------------------

## Public so the selftest can feed canned JSON with no HTTP — the same reason
## WeatherService.parse_forecast_json is public.
func parse_air_quality_json(text: String, lat: float, lon: float,
		fetched_date: String = "", fetched_unix: float = -1.0) -> bool:
	# JSON.parse_string() PUSHES AN ERROR on malformed input before returning
	# null. A rate-limited or misconfigured endpoint answers with an HTML error
	# page, which would then spam a scary parse error into a log where the
	# project's own convention is to read stray errors as real bugs (see the
	# selftest note in CLAUDE.md). JSON.new().parse() returns a status code
	# instead, so a bad response degrades quietly into "no data".
	var j := JSON.new()
	if j.parse(text) != OK:
		return false
	var parsed: Variant = j.data
	if not (parsed is Dictionary):
		return false
	var hourly: Dictionary = (parsed as Dictionary).get("hourly", {}) as Dictionary
	if hourly.is_empty():
		return false
	var times: Array = hourly.get("time", []) as Array
	if times.is_empty():
		return false
	var start_abs := iso_to_abs_hours(str(times[0]))
	if is_nan(start_abs):
		return false

	var new_series: Dictionary = {}
	for var_name in AQ_VARS.split(","):
		var raw: Array = hourly.get(var_name, []) as Array
		if raw.is_empty():
			continue
		var arr := PackedFloat32Array()
		arr.resize(raw.size())
		var any_real := false
		for i in raw.size():
			var v: Variant = raw[i]
			if v is float or v is int:
				arr[i] = float(v)
				any_real = true
			else:
				arr[i] = NAN
		# An all-null column means this model does not carry the field at this
		# location. Storing it would make "unsupported" indistinguishable from
		# "clean", so drop it and let available_vars() report the truth.
		if any_real:
			new_series[var_name] = arr
	if new_series.is_empty():
		return false

	_series = new_series
	_start_abs = start_abs
	_lat = lat
	_lon = lon
	_fetched_date = fetched_date if not fetched_date.is_empty() else _today_date_str()
	_fetched_unix = fetched_unix if fetched_unix > 0.0 else Time.get_unix_time_from_system()
	return true


## "YYYY-MM-DDTHH:MM" (local, timezone=auto) -> absolute hours on the
## CelestialClock epoch. Static and pure so the selftest can pin it.
static func iso_to_abs_hours(iso: String) -> float:
	var t_parts := iso.split("T")
	if t_parts.size() < 2:
		return NAN
	var d_parts := t_parts[0].split("-")
	var h_parts := t_parts[1].split(":")
	if d_parts.size() < 3 or h_parts.is_empty():
		return NAN
	var clk := CelestialClock.new()
	clk.year = int(d_parts[0])
	clk.month = clampi(int(d_parts[1]), 1, 12)
	clk.day = clampi(int(d_parts[2]), 1, 31)
	var hour := float(int(h_parts[0]))
	if h_parts.size() > 1:
		hour += float(int(h_parts[1])) / 60.0
	clk.day_time = clampf(hour, 0.0, 23.999)
	return clk.get_absolute_hours()


## --- fetch plumbing ----------------------------------------------------------

func _on_completed(result: int, code: int, _headers: PackedStringArray,
		body: PackedByteArray) -> void:
	if not _fetching:
		return
	var pending: Dictionary = get_meta("pending", {})
	var lat := float(pending.get("lat", NAN))
	var lon := float(pending.get("lon", NAN))

	if result != HTTPRequest.RESULT_SUCCESS:
		_fail("fetch failed (result %d, HTTP %d)" % [result, code])
		return
	if code == 429 or code >= 500:
		_retries += 1
		if _retries > MAX_RETRIES:
			_fail("rate limited (HTTP %d) after %d retries" % [code, MAX_RETRIES])
			return
		var delay := RETRY_BACKOFF * float(_retries)
		get_tree().create_timer(delay).timeout.connect(func() -> void:
			if _fetching and not _pending_url.is_empty():
				_http.request(_pending_url), CONNECT_ONE_SHOT)
		return
	if code != 200:
		_fail("HTTP %d: %s" % [code, body.get_string_from_utf8().substr(0, 240)])
		return

	var text := body.get_string_from_utf8()
	_fetching = false
	if not parse_air_quality_json(text, lat, lon):
		air_quality_failed.emit("unparseable air-quality response")
		return
	_write_cache(text, lat, lon)
	print("AirQualityService: loaded %d hourly samples (%s) for %.4f, %.4f" % [
		_longest_series_size(), ", ".join(available_vars()), lat, lon])
	air_quality_ready.emit(lat, lon)


func _fail(reason: String) -> void:
	_fetching = false
	_pending_url = ""
	push_warning("AirQualityService: %s" % reason)
	air_quality_failed.emit(reason)


func _longest_series_size() -> int:
	var n := 0
	for k: String in _series.keys():
		n = maxi(n, (_series[k] as PackedFloat32Array).size())
	return n


func _index_for(abs_hours: float) -> int:
	if not has_data() or not is_finite(abs_hours):
		return -1
	var pos := abs_hours - _start_abs
	if pos < 0.0 or pos >= float(_longest_series_size()):
		return -1
	return int(floor(pos))


func _location_mismatch(lat: float, lon: float) -> bool:
	return is_nan(_lat) \
		or absf(lat - _lat) > COVERAGE_EPSILON_DEG \
		or absf(lon - _lon) > COVERAGE_EPSILON_DEG


func _is_stale(lat: float, lon: float) -> bool:
	if not has_data():
		return true
	if _location_mismatch(lat, lon):
		return true
	if _fetched_date != _today_date_str():
		return true
	if _fetched_unix <= 0.0:
		return true
	return Time.get_unix_time_from_system() - _fetched_unix > MAX_AGE_SEC


static func _cache_path(lat: float, lon: float) -> String:
	return "%s/aq_%s_%.4f_%.4f.json" % [CACHE_DIR, CACHE_VERSION, lat, lon]


func _try_load_cache(lat: float, lon: float) -> bool:
	var text := _read_cache_text(_cache_path(lat, lon))
	if text.is_empty():
		return false
	var j := JSON.new()
	if j.parse(text) != OK:
		return false
	var parsed: Variant = j.data
	if not (parsed is Dictionary):
		return false
	var d := parsed as Dictionary
	if str(d.get("cache_version", "")) != CACHE_VERSION:
		return false
	if absf(float(d.get("lat", 999.0)) - lat) > COVERAGE_EPSILON_DEG \
			or absf(float(d.get("lon", 999.0)) - lon) > COVERAGE_EPSILON_DEG:
		return false
	var body := str(d.get("response_text", ""))
	if body.is_empty():
		return false
	var ok := parse_air_quality_json(body, lat, lon,
		str(d.get("fetched_date", "")), float(d.get("fetched_unix", -1.0)))
	if ok:
		print("AirQualityService: served from cache — no download")
		air_quality_ready.emit.call_deferred(lat, lon)
	return ok


func _write_cache(response_text: String, lat: float, lon: float) -> void:
	var payload := {
		"cache_version": CACHE_VERSION,
		"fetched_date": _fetched_date,
		"fetched_unix": _fetched_unix,
		"lat": lat,
		"lon": lon,
		"response_text": response_text,
	}
	var f := FileAccess.open(_cache_path(lat, lon), FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(payload))
	f.close()


func _read_cache_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var nbytes := f.get_length()
	if nbytes <= 0 or nbytes > MAX_CACHE_BYTES:
		f.close()
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		return ""
	var text := f.get_as_text()
	f.close()
	return text


static func _today_date_str() -> String:
	var d := Time.get_date_dict_from_system()
	return "%d-%02d-%02d" % [int(d.year), int(d.month), int(d.day)]


func _resolve_main() -> void:
	if _main_node != null and is_instance_valid(_main_node):
		return
	_main_node = null
	var tree := get_tree()
	if tree == null:
		return
	for child in tree.root.get_children():
		if "day_time" in child and "sun" in child:
			_main_node = child
			return
	var scene := tree.current_scene
	if scene != null and "day_time" in scene:
		_main_node = scene
