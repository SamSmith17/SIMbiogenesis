extends Node

## GistempService — fetches NASA GISTEMP v4 annual global temperature anomaly data.
##
## Source: https://data.giss.nasa.gov/gistemp/tabledata_v4/GLB.Ts+dSST.csv
## Data: annual mean temperature anomaly (°C vs. 1951–1980 baseline).
## Used by the Record Book Modal to tint per-year chart columns.
##
## Cache: user://weather_cache/gistemp.json — refreshed once per calendar year.
## Offline behavior: get_anomaly() returns NAN; callers must degrade gracefully.

signal gistemp_ready()
signal gistemp_failed(reason: String)

const GISTEMP_URL  := "https://data.giss.nasa.gov/gistemp/tabledata_v4/GLB.Ts+dSST.csv"
const CACHE_DIR    := "user://weather_cache"
const CACHE_PATH   := "user://weather_cache/gistemp.json"

var _http: HTTPRequest = null
var _fetching: bool = false
## Keyed year(int) → anomaly(float in °C).
var _anomalies: Dictionary = {}
var _fetch_year: int = 0   # calendar year at last successful parse


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE_DIR))
	_try_load_cache()
	# Network fetch runs when the Climate Record Book opens (request_gistemp).


func _ensure_http() -> void:
	if _http != null and is_instance_valid(_http):
		return
	_http = HTTPRequest.new()
	_http.timeout = 30.0
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)


## ---------------------------------------------------------------------------
## Public API
## ---------------------------------------------------------------------------

## Returns the global annual temperature anomaly (°C vs 1951–1980 baseline) for
## the given year. Returns NAN when not loaded or when data is missing for that year.
func get_anomaly(year: int) -> float:
	var v: Variant = _anomalies.get(year, null)
	return float(v) if v != null else NAN


func has_data() -> bool:
	return not _anomalies.is_empty()


## Returns the 1-based global warmth rank of a year (1 = hottest on record).
## Returns -1 when data is unavailable for that year.
func rank_of_year(year: int) -> int:
	var anomaly := get_anomaly(year)
	if is_nan(anomaly):
		return -1
	var rank := 1
	for yr in _anomalies.keys():
		if float(_anomalies[yr]) > anomaly:
			rank += 1
	return rank


## Returns the top-N warmest years globally, sorted hottest first.
func hottest_years(n: int) -> Array[int]:
	var pairs: Array = []
	for yr in _anomalies.keys():
		pairs.append([yr, _anomalies[yr]])
	pairs.sort_custom(func(a: Array, b: Array) -> bool: return float(a[1]) > float(b[1]))
	var result: Array[int] = []
	for i in mini(n, pairs.size()):
		result.append(int(pairs[i][0]))
	return result


## Trigger a fetch if data is not loaded or the cache is stale (calendar-year TTL).
## Safe to call multiple times; no-ops while a fetch is in progress.
func request_gistemp() -> void:
	if _fetching:
		return
	if has_data() and _fetch_year >= _current_calendar_year():
		gistemp_ready.emit.call_deferred()
		return
	if _try_load_cache():
		gistemp_ready.emit.call_deferred()
		return
	_ensure_http()
	var err := _http.request(GISTEMP_URL)
	if err != OK:
		gistemp_failed.emit.call_deferred("HTTPRequest error %d" % err)
		return
	_fetching = true


## ---------------------------------------------------------------------------
## Fetch + parse
## ---------------------------------------------------------------------------

func _on_request_completed(result: int, response_code: int,
		_headers: PackedStringArray, body: PackedByteArray) -> void:
	_fetching = false
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		gistemp_failed.emit("fetch failed (result %d, HTTP %d)" % [result, response_code])
		return
	var text := body.get_string_from_utf8()
	if not _parse_csv(text):
		gistemp_failed.emit("unparseable GISTEMP CSV response")
		return
	var cache_data := { "fetch_year": _current_calendar_year(), "anomalies": _anomalies }
	var f := FileAccess.open(CACHE_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(cache_data))
		f.close()
	gistemp_ready.emit()


## Parses the GISTEMP annual CSV. The J-D column (annual mean) is the one we use.
## GISTEMP uses "****" as a missing-value sentinel.
func _parse_csv(text: String) -> bool:
	var lines := text.split("\n")
	var header_found := false
	var jd_col := -1
	var new_anomalies: Dictionary = {}
	for line in lines:
		var trimmed := line.strip_edges()
		if trimmed.is_empty():
			continue
		if not header_found:
			if trimmed.begins_with("Year"):
				header_found = true
				var cols := trimmed.split(",")
				for i in cols.size():
					if cols[i].strip_edges() == "J-D":
						jd_col = i
						break
			continue
		if jd_col < 0:
			continue
		var cols := trimmed.split(",")
		if cols.size() <= jd_col:
			continue
		var year_s := cols[0].strip_edges()
		var jd_s   := cols[jd_col].strip_edges()
		if not year_s.is_valid_int():
			continue
		if jd_s.is_empty() or jd_s == "****":
			continue
		if not jd_s.is_valid_float():
			continue
		new_anomalies[int(year_s)] = float(jd_s)
	if new_anomalies.is_empty():
		return false
	_anomalies = new_anomalies
	_fetch_year = _current_calendar_year()
	return true


func _try_load_cache() -> bool:
	if not FileAccess.file_exists(CACHE_PATH):
		return false
	var f := FileAccess.open(CACHE_PATH, FileAccess.READ)
	if f == null:
		return false
	var text := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return false
	var d := parsed as Dictionary
	if int(d.get("fetch_year", 0)) < _current_calendar_year():
		return false
	var anom: Variant = d.get("anomalies", null)
	if not (anom is Dictionary) or (anom as Dictionary).is_empty():
		return false
	_anomalies = anom as Dictionary
	_fetch_year = int(d.get("fetch_year", 0))
	return true


static func _current_calendar_year() -> int:
	return int(Time.get_date_dict_from_system().year)
