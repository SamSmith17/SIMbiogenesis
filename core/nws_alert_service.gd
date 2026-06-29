extends Node

## NwsAlertService — fetches NWS Watch/Warning/Advisory alerts for the current
## NWS UGC zone and converts them onto the absolute-hours timeline axis.
##
## Active alerts: api.weather.gov/alerts/active?zone={ugc} — 15-min TTL.
## Historical alerts: mesonet.agron.iastate.edu vtec_events_byugc — one fetch per
##   UGC zone (the year= param is ignored by IEM); events bucketed by issue year.
##
## Depends on NwsZoneService for the UGC zone code. If no zone is available
## (non-US location, offline, or still loading) all accessors return empty arrays.
##
## Offline / non-US behavior: empty arrays; no errors surfaced to the UI.

signal alerts_ready(ugc_zone: String)
signal alerts_failed(reason: String)
## Emitted after each IEM batch-year fetch completes (for progressive chart redraws).
signal hist_year_loaded(ugc: String, year: int)
## Emitted when the full request_all_hist_years() batch is done.
signal all_hist_years_ready(ugc: String)

const NWS_ACTIVE_URL := "https://api.weather.gov/alerts/active?zone={ugc}"
## IEM vtec_events_byugc: full zone history. year= is required by the URL but
## ignored by IEM — a placeholder current year is substituted at request time.
const IEM_HIST_URL := "https://mesonet.agron.iastate.edu/json/vtec_events_byugc.py?ugc={ugc}&year={year}"
const CACHE_DIR := "user://weather_cache"
const ACTIVE_TTL_SECONDS := 15 * 60   # 15 minutes
const POLL_INTERVAL := 60.0           # check for stale active data every 60 s

var _NWS_HEADERS := PackedStringArray([
	"User-Agent: SIMbiogenesis-NwsAlert/1.0 (notsamsmith@gmail.com)",
	"Accept: application/geo+json",
])
var _IEM_HEADERS := PackedStringArray([
	"User-Agent: SIMbiogenesis-NwsAlert/1.0 (notsamsmith@gmail.com)",
	"Accept: application/json",
])

var _http_active: HTTPRequest = null
var _http_hist: HTTPRequest = null
var _busy_active: bool = false
var _busy_hist: bool = false

## In-memory alert storage. Each entry:
## { id, event, severity, onset_abs (float), expires_abs (float), category }
var _active_alerts: Array[Dictionary] = []
var _hist_alerts: Dictionary = {}     # year(int) -> Array[Dictionary]

var _loaded_ugc: String = ""
var _loaded_hist_year: int = 0        # sim year for timeline range queries
var _active_fetched_unix: float = 0.0
## UGC zone for which the full IEM history has been fetched and bucketed.
var _hist_zone_loaded: String = ""

## Pending zone codes waiting for a single IEM fetch.
var _hist_queue: Array[String] = []
var _batch_ugc: String = ""
var _batch_from_year: int = 1986
var _batch_to_year: int = 0

var _main_node: Node = null
var _poll_acc: float = 0.0


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE_DIR))
	_ensure_http()
	set_process(true)


func _ensure_http() -> void:
	if _http_active == null or not is_instance_valid(_http_active):
		_http_active = HTTPRequest.new()
		_http_active.timeout = 20.0
		add_child(_http_active)
		_http_active.request_completed.connect(_on_active_completed)
	if _http_hist == null or not is_instance_valid(_http_hist):
		_http_hist = HTTPRequest.new()
		_http_hist.timeout = 60.0
		add_child(_http_hist)
		_http_hist.request_completed.connect(_on_hist_completed)


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
	var ugc := NwsZoneService.get_ugc_zone(float(lat), float(lon))
	if ugc.is_empty():
		return  # Zone not yet resolved or non-US location.
	# Active alerts only — full IEM history loads when Record Book opens.
	if not _busy_active:
		var stale := ugc != _loaded_ugc \
			or Time.get_unix_time_from_system() - _active_fetched_unix > ACTIVE_TTL_SECONDS
		if stale:
			_request_active(ugc)
	var yr: Variant = _main_node.get("year")
	var sim_year := int(yr) if yr != null else 0
	if sim_year > 0:
		_loaded_hist_year = sim_year


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

## Returns all alert entries (active + historical for loaded year) whose time
## spans overlap the given absolute-hours range [from_abs, to_abs].
func get_alerts_in_range(from_abs: float, to_abs: float) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for alert in _active_alerts:
		var a0 := float(alert.get("onset_abs", NAN))
		var a1 := float(alert.get("expires_abs", NAN))
		if not is_nan(a0) and not is_nan(a1) and a1 >= from_abs and a0 <= to_abs:
			result.append(alert)
	var hist_arr: Array = _hist_alerts.get(_loaded_hist_year, []) as Array
	for alert in hist_arr:
		var a0 := float(alert.get("onset_abs", NAN))
		var a1 := float(alert.get("expires_abs", NAN))
		if not is_nan(a0) and not is_nan(a1) and a1 >= from_abs and a0 <= to_abs:
			result.append(alert)
	return result


func has_alerts_for_ugc(ugc: String) -> bool:
	return _loaded_ugc == ugc and (not _active_alerts.is_empty() or not _hist_alerts.is_empty())


## Returns the number of alerts in the given year's historical data:
##   ≥0 = loaded (may be 0 if no events),  -1 = not yet fetched.
func get_alert_count_for_year(ugc: String, year: int) -> int:
	if ugc.is_empty() or ugc != _hist_zone_loaded:
		return -1
	var raw: Variant = _hist_alerts.get(year, null)
	if raw == null:
		return -1
	return (raw as Array).size()


## Returns the raw alert list for a given year (empty when not loaded).
func get_alert_events_for_year(ugc: String, year: int) -> Array[Dictionary]:
	if ugc.is_empty() or ugc != _hist_zone_loaded:
		return []
	var raw: Variant = _hist_alerts.get(year, null)
	if raw == null:
		return []
	var arr := raw as Array
	var result: Array[Dictionary] = []
	for item in arr:
		if item is Dictionary:
			result.append(item as Dictionary)
	return result


## Load full IEM history for [from_year, to_year], bucketed by issue year.
## Emits hist_year_loaded for each year in range, then all_hist_years_ready.
## Safe to call multiple times; skips work when the zone is already loaded.
func request_all_hist_years(ugc: String, from_year: int, to_year: int) -> void:
	if ugc.is_empty():
		return
	_batch_ugc = ugc
	_batch_from_year = from_year
	_batch_to_year = to_year

	if ugc != _hist_zone_loaded:
		_hist_alerts.clear()
		_hist_zone_loaded = ""

	if _hist_zone_loaded == ugc and _years_loaded(from_year, to_year):
		all_hist_years_ready.emit.call_deferred(ugc)
		return

	var cache_path := _zone_hist_cache_path(ugc)
	if FileAccess.file_exists(cache_path):
		var f := FileAccess.open(cache_path, FileAccess.READ)
		if f != null:
			var text := f.get_as_text()
			f.close()
			if _ingest_zone_hist(ugc, text, from_year, to_year):
				_emit_hist_range_loaded(ugc, from_year, to_year)
				all_hist_years_ready.emit.call_deferred(ugc)
				return

	if ugc in _hist_queue:
		return
	_hist_queue.append(ugc)
	if not _busy_hist:
		_process_hist_queue()


func _years_loaded(from_year: int, to_year: int) -> bool:
	for yr in range(from_year, to_year + 1):
		if not _hist_alerts.has(yr):
			return false
	return true


func _process_hist_queue() -> void:
	if _hist_queue.is_empty():
		if not _batch_ugc.is_empty() and _hist_zone_loaded == _batch_ugc:
			all_hist_years_ready.emit(_batch_ugc)
		return
	if _busy_hist:
		return
	var ugc: String = _hist_queue.pop_front()
	_request_zone_hist(ugc)


func _emit_hist_range_loaded(_ugc: String, _from_year: int, _to_year: int) -> void:
	# Batch load complete — record book listens to all_hist_years_ready only.
	pass


## Maps an NWS event string to a display category.
## Ends with "Warning" → "warning", "Watch" → "watch", else "advisory".
static func category_for_event(event: String) -> String:
	if event.ends_with("Warning"):
		return "warning"
	if event.ends_with("Watch"):
		return "watch"
	return "advisory"


## Color for drawing alert spans on the timeline track.
static func color_for_category(cat: String) -> Color:
	match cat:
		"warning":  return Color(1.0, 0.20, 0.20, 0.30)
		"watch":    return Color(1.0, 0.60, 0.10, 0.30)
		_:          return Color(1.0, 0.90, 0.20, 0.25)


## ---------------------------------------------------------------------------
## Active alerts fetch (NWS API)
## ---------------------------------------------------------------------------

func _request_active(ugc: String) -> void:
	# Cache hit within TTL?
	var cache_path := _active_cache_path(ugc)
	if FileAccess.file_exists(cache_path):
		var f := FileAccess.open(cache_path, FileAccess.READ)
		if f != null:
			var text := f.get_as_text()
			f.close()
			var alerts := _parse_nws_active(text)
			if alerts != null:
				_active_alerts = alerts
				_active_fetched_unix = _cache_fetched_unix(text)
				if not is_nan(_active_fetched_unix) \
						and Time.get_unix_time_from_system() - _active_fetched_unix <= ACTIVE_TTL_SECONDS:
					if ugc != _loaded_ugc:
						_loaded_ugc = ugc
					alerts_ready.emit.call_deferred(ugc)
					return
	_ensure_http()
	var url := NWS_ACTIVE_URL.replace("{ugc}", ugc)
	var err := _http_active.request(url, _NWS_HEADERS)
	if err != OK:
		alerts_failed.emit.call_deferred("active HTTPRequest error %d" % err)
		return
	_busy_active = true
	set_meta("pending_active_ugc", ugc)


func _on_active_completed(result: int, response_code: int,
		_headers: PackedStringArray, body: PackedByteArray) -> void:
	_busy_active = false
	var ugc := str(get_meta("pending_active_ugc", ""))
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		alerts_failed.emit("active fetch failed (result %d, HTTP %d)" % [result, response_code])
		return
	var text := body.get_string_from_utf8()
	var alerts := _parse_nws_active(text)
	if alerts == null:
		alerts_failed.emit("unparseable active alerts response")
		return
	_active_alerts = alerts
	_active_fetched_unix = Time.get_unix_time_from_system()
	_loaded_ugc = ugc
	# Persist with fetch timestamp injected.
	var payload := {"fetched_unix": _active_fetched_unix, "raw": text}
	var f := FileAccess.open(_active_cache_path(ugc), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(payload))
		f.close()
	alerts_ready.emit(ugc)


## Parses the NWS GeoJSON FeatureCollection into alert dicts. Returns null on error.
func _parse_nws_active(text: String) -> Array[Dictionary]:
	# Text may be the raw GeoJSON or our wrapped {"fetched_unix":…,"raw":…} format.
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return []
	var d := parsed as Dictionary
	# Unwrap our cache envelope if present.
	if d.has("raw"):
		parsed = JSON.parse_string(str(d.get("raw", "")))
		if not (parsed is Dictionary):
			return []
		d = parsed as Dictionary
	var features: Array = d.get("features", []) as Array
	var result: Array[Dictionary] = []
	for feat_var in features:
		if not (feat_var is Dictionary):
			continue
		var feat := feat_var as Dictionary
		var props: Dictionary = feat.get("properties", {}) as Dictionary
		var onset_str := str(props.get("onset", ""))
		var expires_str := str(props.get("expires", ""))
		if onset_str.is_empty() or expires_str.is_empty():
			continue
		var onset_abs := _iso_to_abs_hours(onset_str)
		var expires_abs := _iso_to_abs_hours(expires_str)
		if is_nan(onset_abs) or is_nan(expires_abs):
			continue
		var event := str(props.get("event", ""))
		result.append({
			"id": str(props.get("id", "")),
			"event": event,
			"severity": str(props.get("severity", "")),
			"onset_abs": onset_abs,
			"expires_abs": expires_abs,
			"category": category_for_event(event),
		})
	return result


## ---------------------------------------------------------------------------
## Historical alerts fetch (IEM vtec_events_byugc — one request per zone)
## ---------------------------------------------------------------------------

func _request_zone_hist(ugc: String) -> void:
	var cache_path := _zone_hist_cache_path(ugc)
	if FileAccess.file_exists(cache_path):
		var f := FileAccess.open(cache_path, FileAccess.READ)
		if f != null:
			var text := f.get_as_text()
			f.close()
			if _ingest_zone_hist(ugc, text, _batch_from_year, _batch_to_year):
				_emit_hist_range_loaded(ugc, _batch_from_year, _batch_to_year)
				alerts_ready.emit.call_deferred(ugc)
				all_hist_years_ready.emit.call_deferred(ugc)
				_process_hist_queue()
				return
	_ensure_http()
	var placeholder_year := str(int(Time.get_date_dict_from_system().year))
	var url := IEM_HIST_URL.replace("{ugc}", ugc).replace("{year}", placeholder_year)
	var err := _http_hist.request(url, _IEM_HEADERS)
	if err != OK:
		alerts_failed.emit.call_deferred("hist HTTPRequest error %d" % err)
		_process_hist_queue()
		return
	_busy_hist = true
	set_meta("pending_hist_ugc", ugc)


func _on_hist_completed(result: int, response_code: int,
		_headers: PackedStringArray, body: PackedByteArray) -> void:
	_busy_hist = false
	var ugc := str(get_meta("pending_hist_ugc", ""))
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		push_warning("NwsAlertService: zone hist fetch failed (result %d, HTTP %d) for %s" \
			% [result, response_code, ugc])
		_process_hist_queue()
		return
	var text := body.get_string_from_utf8()
	if _parse_iem_hist(text) == null:
		push_warning("NwsAlertService: unparseable IEM zone hist response for %s" % ugc)
		_process_hist_queue()
		return
	var f := FileAccess.open(_zone_hist_cache_path(ugc), FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()
	if not _ingest_zone_hist(ugc, text, _batch_from_year, _batch_to_year):
		push_warning("NwsAlertService: failed to bucket IEM hist for %s" % ugc)
		_process_hist_queue()
		return
	alerts_ready.emit(ugc)
	_emit_hist_range_loaded(ugc, _batch_from_year, _batch_to_year)
	all_hist_years_ready.emit(ugc)
	_process_hist_queue()


## Parse raw IEM JSON, bucket events by calendar year, mark [from_year, to_year].
func _ingest_zone_hist(ugc: String, text: String, from_year: int, to_year: int) -> bool:
	var events_v: Variant = _parse_iem_hist(text)
	if events_v == null:
		return false
	var events: Array = events_v as Array
	var bucketed := _bucket_events_by_year(events)
	for yr in range(from_year, to_year + 1):
		_hist_alerts[yr] = bucketed.get(yr, [])
	_hist_zone_loaded = ugc
	_loaded_ugc = ugc
	return true


func _bucket_events_by_year(events: Array) -> Dictionary:
	var out: Dictionary = {}
	for item in events:
		if not (item is Dictionary):
			continue
		var alert := item as Dictionary
		var yr := int(alert.get("issue_year", 0))
		if yr <= 0:
			continue
		if not out.has(yr):
			out[yr] = []
		(out[yr] as Array).append(alert)
	return out


## Parses the IEM vtec_events_byugc JSON response into flat alert dicts.
## Returns null on fatal parse error; [] when the response is valid but empty.
func _parse_iem_hist(text: String):
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return null
	var root := parsed as Dictionary
	if not root.has("events"):
		return null
	var events: Array = root.get("events", []) as Array
	var result: Array[Dictionary] = []
	for ev_var in events:
		var entry := _parse_iem_event(ev_var)
		if not entry.is_empty():
			result.append(entry)
	return result


func _parse_iem_event(ev_var: Variant) -> Dictionary:
	if not (ev_var is Dictionary):
		return {}
	var ev := ev_var as Dictionary
	var issue_str := str(ev.get("issue", ev.get("utc_issue", "")))
	var expire_str := str(ev.get("expire", ev.get("utc_expire", "")))
	if issue_str.is_empty() or expire_str.is_empty():
		return {}
	var onset_abs := _iem_timestamp_to_abs_hours(issue_str)
	var expires_abs := _iem_timestamp_to_abs_hours(expire_str)
	if is_nan(onset_abs) or is_nan(expires_abs):
		return {}
	var event_name := str(ev.get("name", "")).strip_edges()
	if event_name.is_empty():
		var phenomena := str(ev.get("phenomena", ""))
		var significance := str(ev.get("significance", ""))
		event_name = _vtec_to_event_name(phenomena, significance)
	return {
		"id": str(ev.get("eventid", "")),
		"event": event_name,
		"severity": "",
		"onset_abs": onset_abs,
		"expires_abs": expires_abs,
		"issue_year": _issue_calendar_year(issue_str),
		"category": category_for_event(event_name),
	}


## ---------------------------------------------------------------------------
## Timestamp helpers
## ---------------------------------------------------------------------------

## Convert an ISO-8601 timestamp (with timezone offset) to absolute hours.
## Returns NAN on parse failure.
func _iso_to_abs_hours(iso: String) -> float:
	# Godot 4: Time.get_unix_time_from_datetime_string handles ISO-8601 with
	# timezone offsets (e.g. "2023-06-08T10:00:00-07:00").
	var unix_ts := Time.get_unix_time_from_datetime_string(iso)
	if is_nan(unix_ts) or unix_ts <= 0.0:
		return NAN
	return _unix_to_abs(unix_ts)


## Convert an IEM issue/expire timestamp to absolute hours.
## Accepts ISO-8601 ("2005-10-21T08:34:00Z") or legacy "YYYY-MM-DD HH:MM".
func _iem_timestamp_to_abs_hours(ts: String) -> float:
	if ts.contains("T"):
		return _iso_to_abs_hours(ts)
	return _iem_utc_to_abs_hours(ts)


static func _issue_calendar_year(issue_str: String) -> int:
	if issue_str.length() < 4:
		return 0
	return int(issue_str.substr(0, 4))


## Convert an IEM UTC datetime string "YYYY-MM-DD HH:MM" to absolute hours.
func _iem_utc_to_abs_hours(utc_str: String) -> float:
	# Reformat to ISO-8601 so Godot can parse it.
	var parts := utc_str.replace(" ", "T")
	if not parts.contains("T"):
		return NAN
	var unix_ts := Time.get_unix_time_from_datetime_string(parts + ":00+00:00")
	if is_nan(unix_ts) or unix_ts <= 0.0:
		return NAN
	return _unix_to_abs(unix_ts)


## Convert a Unix timestamp to absolute hours using CelestialClock.
func _unix_to_abs(unix_ts: float) -> float:
	if _main_node == null or not is_instance_valid(_main_node):
		_resolve_main()
	if _main_node == null or not is_instance_valid(_main_node):
		return NAN
	var clk: Variant = _main_node.get("clock")
	if clk == null or not clk.has_method("unix_to_abs_hours"):
		return NAN
	return float(clk.unix_to_abs_hours(unix_ts))


## Map VTEC phenomena+significance codes to a human-readable event name.
## The name is used for category_for_event() suffix matching.
static func _vtec_to_event_name(phenomena: String, significance: String) -> String:
	var sig_suffix: String
	match significance:
		"W": sig_suffix = "Warning"
		"A": sig_suffix = "Watch"
		"Y": sig_suffix = "Advisory"
		"S": sig_suffix = "Statement"
		_:   sig_suffix = significance
	var phenomena_name: String
	match phenomena:
		"TO": phenomena_name = "Tornado"
		"SV": phenomena_name = "Severe Thunderstorm"
		"FF": phenomena_name = "Flash Flood"
		"FA": phenomena_name = "Flood"
		"MA": phenomena_name = "Marine"
		"HT": phenomena_name = "Heat"
		"EC": phenomena_name = "Extreme Cold"
		"WI": phenomena_name = "Wind"
		"EW": phenomena_name = "Extreme Wind"
		"WS": phenomena_name = "Winter Storm"
		"WW": phenomena_name = "Winter Weather"
		"BZ": phenomena_name = "Blizzard"
		"IS": phenomena_name = "Ice Storm"
		"HS": phenomena_name = "Heavy Snow"
		"FW": phenomena_name = "Red Flag"
		"DS": phenomena_name = "Dust Storm"
		"DU": phenomena_name = "Blowing Dust"
		"FZ": phenomena_name = "Freeze"
		"FR": phenomena_name = "Frost"
		"HZ": phenomena_name = "Hard Freeze"
		"FG": phenomena_name = "Dense Fog"
		"SM": phenomena_name = "Dense Smoke"
		_:   phenomena_name = phenomena
	return "%s %s" % [phenomena_name, sig_suffix]


## ---------------------------------------------------------------------------
## Cache path helpers
## ---------------------------------------------------------------------------

static func _active_cache_path(ugc: String) -> String:
	return "%s/alerts_active_%s.json" % [CACHE_DIR, ugc]


static func _zone_hist_cache_path(ugc: String) -> String:
	return "%s/alerts_hist_zone_%s.json" % [CACHE_DIR, ugc]


static func _cache_fetched_unix(text: String) -> float:
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		return float((parsed as Dictionary).get("fetched_unix", NAN))
	return NAN
