extends Node

## NwsZoneService — resolves a lat/lon to an NWS UGC forecast zone code and
## the name/ICAO of the nearest official observation station.
##
## Used by NwsAlertService (needs the UGC zone for alert queries) and by the
## timeline provenance tooltip (needs the station name for display).
##
## API: api.weather.gov — free, no key required. Returns 404 for locations
## outside the US; all getters degrade gracefully to "" in that case.
##
## Cache: user://weather_cache/nws_zone_{lat4}_{lon4}.json, 30-day TTL.
## Offline behavior: all getters return ""; callers check has_zone() first.

signal zone_ready(lat: float, lon: float, ugc_zone: String, station_name: String, station_icao: String)
signal zone_failed(reason: String)

const POINTS_URL := "https://api.weather.gov/points/{lat},{lon}"
const CACHE_DIR := "user://weather_cache"
const CACHE_TTL_SECONDS := 30 * 24 * 3600  # 30 days
const LOCATION_POLL_INTERVAL := 10.0
const COVERAGE_EPSILON_DEG := 0.05  # match WeatherService

## NWS requires a User-Agent with contact info in policy.
var _HEADERS := PackedStringArray([
	"User-Agent: SIMbiogenesis-NwsZone/1.0 (notsamsmith@gmail.com)",
	"Accept: application/geo+json",
])

var _http_points: HTTPRequest = null
var _http_stations: HTTPRequest = null
var _busy: bool = false

## Loaded zone data.
var _zone_lat: float = NAN
var _zone_lon: float = NAN
var _ugc_zone: String = ""
var _county_zone: String = ""
var _station_name: String = ""
var _station_icao: String = ""

## Pending state across the two-step fetch.
var _pending_lat: float = NAN
var _pending_lon: float = NAN
var _pending_ugc: String = ""
var _pending_county: String = ""
var _pending_stations_url: String = ""

var _main_node: Node = null
var _poll_acc: float = 0.0


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE_DIR))
	_ensure_http()
	set_process(true)


func _ensure_http() -> void:
	if _http_points == null or not is_instance_valid(_http_points):
		_http_points = HTTPRequest.new()
		_http_points.timeout = 20.0
		add_child(_http_points)
		_http_points.request_completed.connect(_on_points_completed)
	if _http_stations == null or not is_instance_valid(_http_stations):
		_http_stations = HTTPRequest.new()
		_http_stations.timeout = 20.0
		add_child(_http_stations)
		_http_stations.request_completed.connect(_on_stations_completed)


func _process(delta: float) -> void:
	_poll_acc += delta
	if _poll_acc < LOCATION_POLL_INTERVAL:
		return
	_poll_acc = 0.0
	_resolve_main()
	if _main_node == null or _busy:
		return
	var lat: Variant = _main_node.get("latitude")
	var lon: Variant = _main_node.get("longitude")
	if lat == null or lon == null:
		return
	var location_changed := is_nan(_zone_lat) \
		or absf(float(lat) - _zone_lat) > COVERAGE_EPSILON_DEG \
		or absf(float(lon) - _zone_lon) > COVERAGE_EPSILON_DEG
	if location_changed:
		request_zone(float(lat), float(lon))


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


## ---------------------------------------------------------------------------
## Public API
## ---------------------------------------------------------------------------

func request_zone(lat: float, lon: float) -> void:
	if _busy:
		return
	# Cache hit?
	var cache_path := _cache_path(lat, lon)
	if FileAccess.file_exists(cache_path):
		var f := FileAccess.open(cache_path, FileAccess.READ)
		if f != null:
			var text := f.get_as_text()
			f.close()
			if _load_from_cache(text, lat, lon):
				zone_ready.emit.call_deferred(lat, lon, _ugc_zone, _station_name, _station_icao)
				return
	_ensure_http()
	var url := POINTS_URL.replace("{lat}", "%.4f" % lat).replace("{lon}", "%.4f" % lon)
	var err := _http_points.request(url, _HEADERS)
	if err != OK:
		zone_failed.emit.call_deferred("HTTPRequest error %d" % err)
		return
	_busy = true
	_pending_lat = lat
	_pending_lon = lon


func has_zone(lat: float, lon: float) -> bool:
	if _ugc_zone.is_empty():
		return false
	return absf(lat - _zone_lat) <= COVERAGE_EPSILON_DEG \
		and absf(lon - _zone_lon) <= COVERAGE_EPSILON_DEG


func get_ugc_zone(lat: float, lon: float) -> String:
	return _ugc_zone if has_zone(lat, lon) else ""


func get_station_name(lat: float, lon: float) -> String:
	return _station_name if has_zone(lat, lon) else ""


func get_station_icao(lat: float, lon: float) -> String:
	return _station_icao if has_zone(lat, lon) else ""


## ---------------------------------------------------------------------------
## Step 1: /points/{lat},{lon}
## ---------------------------------------------------------------------------

func _on_points_completed(result: int, response_code: int,
		_headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		_busy = false
		if response_code == 404:
			# Location outside NWS coverage (non-US) — not an error worth retrying.
			zone_failed.emit("NWS coverage unavailable for this location (non-US?)")
		else:
			zone_failed.emit("points fetch failed (result %d, HTTP %d)" % [result, response_code])
		return
	var text := body.get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		_busy = false
		zone_failed.emit("unparseable points response")
		return
	var props: Dictionary = (parsed as Dictionary).get("properties", {}) as Dictionary
	# forecastZone is a URL like ".../zones/forecast/CAZ048" — extract the last segment.
	var zone_url := str(props.get("forecastZone", ""))
	var county_url := str(props.get("county", ""))
	var stations_url := str(props.get("observationStations", ""))
	if zone_url.is_empty() or stations_url.is_empty():
		_busy = false
		zone_failed.emit("missing forecastZone or observationStations in points response")
		return
	_pending_ugc = zone_url.split("/")[-1]
	_pending_county = county_url.split("/")[-1]
	_pending_stations_url = stations_url
	# Step 2: fetch station list.
	var err := _http_stations.request(stations_url, _HEADERS)
	if err != OK:
		_busy = false
		zone_failed.emit("stations HTTPRequest error %d" % err)


## ---------------------------------------------------------------------------
## Step 2: /gridpoints/.../stations
## ---------------------------------------------------------------------------

func _on_stations_completed(result: int, response_code: int,
		_headers: PackedStringArray, body: PackedByteArray) -> void:
	_busy = false
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		zone_failed.emit("stations fetch failed (result %d, HTTP %d)" % [result, response_code])
		return
	var text := body.get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(text)
	var station_icao := ""
	var station_name := ""
	if parsed is Dictionary:
		var features: Array = (parsed as Dictionary).get("features", []) as Array
		if not features.is_empty():
			var first_props: Dictionary = (features[0] as Dictionary).get("properties", {}) as Dictionary
			station_icao = str(first_props.get("stationIdentifier", ""))
			station_name = str(first_props.get("name", ""))
	# Commit loaded data.
	_ugc_zone = _pending_ugc
	_county_zone = _pending_county
	_station_name = station_name
	_station_icao = station_icao
	_zone_lat = _pending_lat
	_zone_lon = _pending_lon
	# Persist cache.
	var cache_data := {
		"ugc_zone": _ugc_zone,
		"county_zone": _county_zone,
		"station_name": _station_name,
		"station_icao": _station_icao,
		"fetched_unix": Time.get_unix_time_from_system(),
	}
	var f := FileAccess.open(_cache_path(_zone_lat, _zone_lon), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(cache_data))
		f.close()
	zone_ready.emit(_zone_lat, _zone_lon, _ugc_zone, _station_name, _station_icao)


## ---------------------------------------------------------------------------
## Cache helpers
## ---------------------------------------------------------------------------

static func _cache_path(lat: float, lon: float) -> String:
	return "%s/nws_zone_%.4f_%.4f.json" % [CACHE_DIR, lat, lon]


func _load_from_cache(text: String, lat: float, lon: float) -> bool:
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return false
	var d := parsed as Dictionary
	# TTL check.
	var fetched := float(d.get("fetched_unix", 0.0))
	if Time.get_unix_time_from_system() - fetched > CACHE_TTL_SECONDS:
		return false
	var ugc := str(d.get("ugc_zone", ""))
	if ugc.is_empty():
		return false
	_ugc_zone = ugc
	_county_zone = str(d.get("county_zone", ""))
	_station_name = str(d.get("station_name", ""))
	_station_icao = str(d.get("station_icao", ""))
	_zone_lat = lat
	_zone_lon = lon
	return true
