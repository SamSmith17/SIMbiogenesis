extends Node

## ClimateProjectionService — CMIP6 future climate projections 1991–2050.
##
## Fetches monthly-aggregated temperature and precipitation projections for the
## active sim location under a user-selected SSP warming scenario and exposes
## delta-method helpers so WeatherService can shift ERA5 temperatures when the
## RecordBookPanel can extend the chart to 2049.
##
## Data source: Open-Meteo Climate API (no key required, CCBY 4.0).
## Opt-in upgrade: Copernicus CDS CMIP6 (free API key → user://keys_config.cfg).
##   When a CDS key is saved, Record Book fetch uses tools/cds_cmip6_fetch.py
##   (Python + cdsapi + xarray). Falls back to Open-Meteo if CDS is unavailable.
##
## ⚠ Verify SCENARIO_MODELS names against open-meteo.com/en/docs/climate-api
##   before a production run — the model list evolves.

signal projection_ready(lat: float, lon: float, scenario: int)
signal projection_failed(reason: String)
signal scenario_changed(s: int)

## SSP warming scenarios.  Label and representative CMIP6 model per entry.
## LOW=SSP1-2.6 (+1.5°C), MODERATE=SSP2-4.5 (+2°C),
## HIGH=SSP3-7.0 (+3-4°C), VERY_HIGH=SSP5-8.5 (+5°C).
enum Scenario { LOW = 0, MODERATE = 1, HIGH = 2, VERY_HIGH = 3 }

const CLIMATE_URL    := "https://climate-api.open-meteo.com/v1/climate"
const CACHE_DIR      := "user://weather_cache"
const PREFS_PATH     := "user://climate_prefs.cfg"
const KEYS_PATH      := "user://keys_config.cfg"
const CDS_FETCH_SCRIPT := "res://tools/cds_cmip6_fetch.py"
const BASELINE_START := 1991
const BASELINE_END   := 2020
const PROJ_END       := 2050   # Open-Meteo Climate API hard limit
const FETCH_TIMEOUT  := 120.0
const POLL_INTERVAL  := 30.0
const COVERAGE_EPSILON_DEG := 0.05
const MAX_CACHE_BYTES := 25 * 1024 * 1024

## One Open-Meteo CMIP6 model string per Scenario enum value (see climate-api docs).
const SCENARIO_MODELS: Array[String] = [
	"CMCC_CM2_VHR4",  # LOW       SSP1-2.6
	"MPI_ESM1_2_XR",  # MODERATE  SSP2-4.5
	"MRI_AGCM3_2_S",  # HIGH      SSP3-7.0
	"EC_Earth3P_HR",  # VERY_HIGH SSP5-8.5
]

const SCENARIO_LABELS: Array[String] = [
	"Low (+1.5 °C by 2100, SSP1-2.6)",
	"Moderate (+2 °C, SSP2-4.5)",
	"High (+3–4 °C, SSP3-7.0)",
	"Very high (+5 °C, SSP5-8.5)",
]

var active_scenario: int = Scenario.MODERATE

var _http:     HTTPRequest = null
var _fetching: bool        = false
var _fetch_lat: float      = NAN
var _fetch_lon: float      = NAN

## Monthly projections keyed by int year → int month → {temp_max, temp_min, precip}.
## Covers years BASELINE_START–PROJ_END.
var _monthly:  Dictionary = {}
## 1991–2020 monthly means keyed by int month → {temp_max, temp_min, precip}.
var _baseline: Dictionary = {}

var _proj_lat:      float = NAN
var _proj_lon:      float = NAN
var _proj_scenario: int   = -1

## Cached ERA5 daily temps for record-book projection (key "MM-DD" → °C).
var _era5_day_cache: Dictionary = {}

var _main_node:       Node  = null
var _record_book_active: bool = false
var _poll_acc:        float = 0.0
var _data_source:     String = ""
var _cds_thread:      Thread = null
var _cds_thread_pack: Dictionary = {}
var _cds_fetch_lat:   float = NAN
var _cds_fetch_lon:   float = NAN


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE_DIR))
	_load_prefs()
	set_process(false)


func _exit_tree() -> void:
	if _cds_thread != null and _cds_thread.is_started():
		_cds_thread.wait_to_finish()
	_cds_thread = null


func _process(delta: float) -> void:
	_poll_cds_thread()
	if not _record_book_active:
		return
	_poll_acc += delta
	if _poll_acc < POLL_INTERVAL:
		return
	_poll_acc = 0.0
	_resolve_main()
	if _main_node == null:
		return
	var lat_v: Variant = _main_node.get("latitude")
	var lon_v: Variant = _main_node.get("longitude")
	if lat_v == null or lon_v == null:
		return
	var lat := float(lat_v)
	var lon := float(lon_v)
	var drifted := is_nan(_proj_lat) \
		or absf(lat - _proj_lat) > COVERAGE_EPSILON_DEG \
		or absf(lon - _proj_lon) > COVERAGE_EPSILON_DEG
	if drifted or _proj_scenario != active_scenario:
		request_projection(lat, lon)


## Called when the user opens the Climate Record Book — starts lazy fetch/build.
func begin_record_book(lat: float, lon: float) -> void:
	_record_book_active = true
	set_process(true)
	request_projection(lat, lon)


func _resolve_main() -> void:
	if _main_node != null and is_instance_valid(_main_node):
		return
	_main_node = null
	var tree := get_tree()
	if tree == null:
		return
	var root := tree.root
	for child in root.get_children():
		if "day_time" in child and "sun" in child:
			_main_node = child
			return
	var scene := tree.current_scene
	if scene and "day_time" in scene:
		_main_node = scene


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Temperature delta (°C above 1991–2020 baseline) for the given year+month.
## Returns NAN when projections are not loaded.
func get_temp_delta(year: int, month: int) -> float:
	if _monthly.is_empty() or _baseline.is_empty():
		return NAN
	var ym: Variant = _monthly.get(year, null)
	if ym == null:
		ym = _monthly.get(str(year), null)
	if not (ym is Dictionary):
		return NAN
	var mm: Variant = (ym as Dictionary).get(month, null)
	if mm == null:
		mm = (ym as Dictionary).get(str(month), null)
	if not (mm is Dictionary):
		return NAN
	var bm: Variant = _baseline.get(month, null)
	if bm == null:
		bm = _baseline.get(str(month), null)
	if not (bm is Dictionary):
		return NAN
	var mm_d := mm as Dictionary
	var bm_d := bm as Dictionary
	if mm_d.is_empty() or bm_d.is_empty():
		return NAN
	var proj_t := (float(mm_d.get("temp_max", NAN)) + float(mm_d.get("temp_min", NAN))) * 0.5
	var base_t := (float(bm_d.get("temp_max", NAN)) + float(bm_d.get("temp_min", NAN))) * 0.5
	if is_nan(proj_t) or is_nan(base_t):
		return NAN
	return proj_t - base_t


## Precipitation multiplier (ratio to 1991–2020 baseline) for year+month.
## Returns NAN when projections are not loaded or baseline is zero.
func get_precip_factor(year: int, month: int) -> float:
	if _monthly.is_empty() or _baseline.is_empty():
		return NAN
	var ym: Variant = _monthly.get(year, null)
	if ym == null:
		ym = _monthly.get(str(year), null)
	if not (ym is Dictionary):
		return NAN
	var mm: Variant = (ym as Dictionary).get(month, null)
	if mm == null:
		mm = (ym as Dictionary).get(str(month), null)
	if not (mm is Dictionary):
		return NAN
	var bm: Variant = _baseline.get(month, null)
	if bm == null:
		bm = _baseline.get(str(month), null)
	if not (bm is Dictionary):
		return NAN
	var mm_d := mm as Dictionary
	var bm_d := bm as Dictionary
	if mm_d.is_empty() or bm_d.is_empty():
		return NAN
	var proj_p := float(mm_d.get("precip", NAN))
	var base_p := float(bm_d.get("precip", NAN))
	if is_nan(proj_p) or is_nan(base_p) or base_p <= 0.0:
		return NAN
	return proj_p / base_p


## Annual mean temperature anomaly above baseline (average of 12 monthly deltas).
## Returns NAN when projections are not loaded.
func get_projected_anomaly(year: int) -> float:
	var total := 0.0
	var count := 0
	for month in range(1, 13):
		var dt := get_temp_delta(year, month)
		if not is_nan(dt):
			total += dt
			count += 1
	return total / float(count) if count > 0 else NAN


func has_projection() -> bool:
	return not _monthly.is_empty() and not _baseline.is_empty()


func is_fetching() -> bool:
	return _fetching or _cds_thread_active()


func get_data_source() -> String:
	return _data_source


## Fetch projection for lat/lon if cache is stale or missing.
func request_projection(lat: float, lon: float) -> void:
	if is_fetching():
		return
	var cds_key := _read_key(KEYS_PATH, "copernicus", "api_key")
	if not cds_key.is_empty():
		var cds_path := _cds_cache_path(lat, lon, active_scenario)
		if FileAccess.file_exists(cds_path):
			var text := _read_cache_text(cds_path)
			if not text.is_empty() and _load_cache(text):
				_data_source = "cds"
				_proj_lat = lat
				_proj_lon = lon
				_proj_scenario = active_scenario
				projection_ready.emit.call_deferred(lat, lon, active_scenario)
				return
		_start_cds_fetch(lat, lon)
		return
	_fetch_open_meteo(lat, lon)


## Count projected record-breaking days for one calendar month of a future year.
## Spread across frames by the Record Book — one month ≈ 28–31 samples, not 365×12.
func count_record_breaks_for_month(year: int, month: int) -> Dictionary:
	var out := {"highs": 0, "lows": 0}
	if not has_projection():
		return out
	var delta := get_temp_delta(year, month)
	if is_nan(delta):
		return out
	var days_in_month := _days_in_month(month)
	for day in range(1, days_in_month + 1):
		var rec := WeatherService.get_records(month, day)
		if rec.is_empty():
			continue
		var era5_t := _era5_temp_for(month, day)
		if is_nan(era5_t):
			continue
		var projected := era5_t + delta
		# TODO(weather-gen): projected path still uses a single 14:00 sample for both
		# high and low proxy — replace with daily min/max from full archive hourly when
		# the record-book panel needs tighter CMIP6 fallback accuracy.
		var part := RecordBreakCounter.count_day(rec, projected, projected)
		RecordBreakCounter.accumulate(out, part)
	return out


static func _days_in_month(month: int) -> int:
	match clampi(month, 1, 12):
		2:  return 28
		4, 6, 9, 11:  return 30
		_:  return 31


## Estimate projected all-time record-breaking days for a single future year.
## Uses ERA5 sample() (raw, no delta injection) shifted by CMIP6 monthly delta.
## Returns {"highs": int, "lows": int}.
func compute_projected_yearbook_for_year(year: int) -> Dictionary:
	if not has_projection():
		return {"highs": 0, "lows": 0}
	var highs := 0
	var lows  := 0
	for month in range(1, 13):
		var part := count_record_breaks_for_month(year, month)
		highs += int(part.get("highs", 0))
		lows += int(part.get("lows", 0))
	return {"highs": highs, "lows": lows}


func _era5_temp_for(month: int, day: int) -> float:
	var key := "%02d-%02d" % [month, day]
	if _era5_day_cache.has(key):
		return float(_era5_day_cache[key])
	var t := WeatherService.sample("temperature_2m", month, day, 14.0)
	_era5_day_cache[key] = t
	return t


## Switch active scenario → clears loaded data → emits scenario_changed.
## Immediately re-fetches if a location is already known.
func set_scenario(s: int) -> void:
	var new_s := clampi(s, 0, 3)
	if new_s == active_scenario:
		return
	active_scenario = new_s
	_monthly.clear()
	_baseline.clear()
	_era5_day_cache.clear()
	_proj_scenario = -1
	_data_source = ""
	_save_prefs()
	scenario_changed.emit(active_scenario)
	if _record_book_active and not is_nan(_proj_lat) and not is_nan(_proj_lon):
		request_projection(_proj_lat, _proj_lon)


# ---------------------------------------------------------------------------
# CDS CMIP6 (Python cdsapi + xarray extract)
# ---------------------------------------------------------------------------

func _cds_thread_active() -> bool:
	return _cds_thread != null and _cds_thread.is_started()


func _start_cds_fetch(lat: float, lon: float) -> void:
	if _cds_thread_active():
		return
	var python := _find_python_executable()
	var script := ProjectSettings.globalize_path(CDS_FETCH_SCRIPT)
	if python.is_empty() or not FileAccess.file_exists(CDS_FETCH_SCRIPT):
		push_warning("ClimateProjectionService: CDS key set but Python/tools/cds_cmip6_fetch.py unavailable — using Open-Meteo")
		_fetch_open_meteo(lat, lon)
		return
	var out_path := ProjectSettings.globalize_path(_cds_cache_path(lat, lon, active_scenario))
	var keys_path := ProjectSettings.globalize_path(KEYS_PATH)
	var args: PackedStringArray = [
		script,
		"--lat", "%.6f" % lat,
		"--lon", "%.6f" % lon,
		"--scenario", str(active_scenario),
		"--out", out_path,
		"--keys-cfg", keys_path,
	]
	var exec_cmd := python
	var exec_args := args
	if python == "py":
		exec_args = PackedStringArray(["-3"]) + args
	_cds_fetch_lat = lat
	_cds_fetch_lon = lon
	_fetching = true
	_data_source = "cds"
	_cds_thread_pack = {"python": exec_cmd, "args": exec_args, "exit_code": -1, "output": ""}
	_cds_thread = Thread.new()
	_cds_thread.start(_cds_fetch_worker.bind(_cds_thread_pack))


static func _cds_fetch_worker(pack: Dictionary) -> void:
	var output: Array = []
	var code := OS.execute(
		str(pack.get("python", "")),
		pack.get("args", PackedStringArray()),
		output,
		true,
		false
	)
	pack["exit_code"] = code
	pack["output"] = "\n".join(PackedStringArray(output))


func _poll_cds_thread() -> void:
	if not _cds_thread_active():
		return
	if _cds_thread.is_alive():
		return
	var _exit_code: int = int(_cds_thread_pack.get("exit_code", -1))
	_cds_thread.wait_to_finish()
	_cds_thread = null
	_fetching = false
	var lat := _cds_fetch_lat
	var lon := _cds_fetch_lon
	_cds_fetch_lat = NAN
	_cds_fetch_lon = NAN
	var ok := _exit_code == OK
	var out_text := str(_cds_thread_pack.get("output", ""))
	if ok:
		var cds_path := _cds_cache_path(lat, lon, active_scenario)
		var text := _read_cache_text(cds_path)
		ok = not text.is_empty() and _load_cache(text)
	if ok:
		_data_source = "cds"
		_proj_lat = lat
		_proj_lon = lon
		_proj_scenario = active_scenario
		projection_ready.emit(lat, lon, active_scenario)
		return
	push_warning("ClimateProjectionService: CDS CMIP6 fetch failed (exit %d) — %s" \
		% [_exit_code, out_text.substr(0, min(400, out_text.length()))])
	projection_failed.emit("CDS fetch failed")
	_fetch_open_meteo(lat, lon)


static func _find_python_executable() -> String:
	if OS.has_environment("SKY_PYTHON"):
		var from_env := OS.get_environment("SKY_PYTHON").strip_edges()
		if not from_env.is_empty() and FileAccess.file_exists(from_env):
			return from_env
	for cmd in ["python", "python3", "py"]:
		var probe_args: PackedStringArray = ["--version"] if cmd != "py" else PackedStringArray(["-3", "--version"])
		var probe: Array = []
		if OS.execute(cmd, probe_args, probe, true, false) == OK:
			return cmd
	if OS.get_name() == "Windows":
		for ver in ["313", "312", "311", "310"]:
			for root in [
				OS.get_environment("LOCALAPPDATA") + "/Programs/Python/Python%s/python.exe" % ver,
				OS.get_environment("USERPROFILE") + "/AppData/Local/Programs/Python/Python%s/python.exe" % ver,
			]:
				if not root.is_empty() and FileAccess.file_exists(root):
					return root
	return ""


# ---------------------------------------------------------------------------
# Open-Meteo Climate API
# ---------------------------------------------------------------------------

func _fetch_open_meteo(lat: float, lon: float) -> void:
	if _fetching:
		return
	var cache_path := _cache_path(lat, lon, active_scenario)
	var text := _read_cache_text(cache_path)
	if not text.is_empty() and _load_cache(text):
		_data_source = "open_meteo"
		_proj_lat = lat
		_proj_lon = lon
		_proj_scenario = active_scenario
		projection_ready.emit.call_deferred(lat, lon, active_scenario)
		return
	_fetch_open_meteo_network(lat, lon)


func _fetch_open_meteo_network(lat: float, lon: float) -> void:
	_ensure_http()
	var model := SCENARIO_MODELS[clampi(active_scenario, 0, SCENARIO_MODELS.size() - 1)]
	var url := (
		"%s?latitude=%.4f&longitude=%.4f"
		+ "&start_date=%d-01-01&end_date=%d-12-31"
		+ "&models=%s&daily=temperature_2m_max,temperature_2m_min,precipitation_sum"
		+ "&timezone=UTC"
	) % [CLIMATE_URL, lat, lon, BASELINE_START, PROJ_END, model]
	var err := _http.request(url)
	if err != OK:
		_fetching = false
		projection_failed.emit("HTTPRequest error %d" % err)
		return
	_fetching = true
	_data_source = "open_meteo"
	_fetch_lat = lat
	_fetch_lon = lon


func _ensure_http() -> void:
	if _http != null and is_instance_valid(_http):
		return
	_http = HTTPRequest.new()
	_http.timeout = FETCH_TIMEOUT
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)


func _on_request_completed(result: int, response_code: int,
		_headers: PackedStringArray, body: PackedByteArray) -> void:
	_fetching = false
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		push_warning("ClimateProjectionService: fetch failed (result %d, HTTP %d)" \
			% [result, response_code])
		_projection_failed_emit("HTTP %d" % response_code)
		return
	var text := body.get_string_from_utf8()
	if not _parse_and_aggregate(text):
		push_warning("ClimateProjectionService: unparseable response — first 300 chars: %s" \
			% text.substr(0, 300))
		projection_failed.emit("parse error")
		return
	_data_source = "open_meteo"
	_proj_lat      = _fetch_lat
	_proj_lon      = _fetch_lon
	_proj_scenario = active_scenario
	_write_cache(_fetch_lat, _fetch_lon, active_scenario)
	projection_ready.emit(_fetch_lat, _fetch_lon, active_scenario)


func _projection_failed_emit(reason: String) -> void:
	projection_failed.emit(reason)


# ---------------------------------------------------------------------------
# Parsing and aggregation (daily → monthly means)
# ---------------------------------------------------------------------------

func _parse_and_aggregate(text: String) -> bool:
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return false
	var daily: Dictionary = (parsed as Dictionary).get("daily", {}) as Dictionary
	if daily.is_empty():
		return false

	var times:    Array = daily.get("time", []) as Array
	var t_max_arr: Array = daily.get("temperature_2m_max", []) as Array
	var t_min_arr: Array = daily.get("temperature_2m_min", []) as Array
	var prec_arr:  Array = daily.get("precipitation_sum",  []) as Array

	# Fallback: Open-Meteo appends the model name when multiple models are requested.
	if t_max_arr.is_empty():
		var sfx := "_" + SCENARIO_MODELS[clampi(active_scenario, 0, SCENARIO_MODELS.size() - 1)]
		t_max_arr = daily.get("temperature_2m_max" + sfx, []) as Array
		t_min_arr = daily.get("temperature_2m_min" + sfx, []) as Array
		prec_arr  = daily.get("precipitation_sum"  + sfx, []) as Array

	if times.is_empty() or t_max_arr.is_empty():
		return false

	# Accumulate daily values into monthly sums/counts.
	var agg: Dictionary = {}  # int year → int month → {tmax_sum, tmin_sum, prec_sum, count}
	for i in times.size():
		var date_str := str(times[i])
		if date_str.length() < 10:
			continue
		var yr := int(date_str.substr(0, 4))
		var mo := int(date_str.substr(5, 2))
		if yr < BASELINE_START or yr > PROJ_END or mo < 1 or mo > 12:
			continue
		var tmax_v: Variant = t_max_arr[i] if i < t_max_arr.size() else null
		var tmin_v: Variant = t_min_arr[i] if i < t_min_arr.size() else null
		var prec_v: Variant = prec_arr[i]  if i < prec_arr.size()  else null
		var tmax := float(tmax_v) if (tmax_v is float or tmax_v is int) else NAN
		var tmin := float(tmin_v) if (tmin_v is float or tmin_v is int) else NAN
		var prec := float(prec_v) if (prec_v is float or prec_v is int) else 0.0
		if is_nan(tmax) and is_nan(tmin):
			continue
		if not agg.has(yr):
			agg[yr] = {}
		if not (agg[yr] as Dictionary).has(mo):
			(agg[yr] as Dictionary)[mo] = {
				"tmax_sum": 0.0, "tmin_sum": 0.0, "prec_sum": 0.0, "count": 0
			}
		var cell := (agg[yr] as Dictionary)[mo] as Dictionary
		if not is_nan(tmax):
			cell["tmax_sum"] = float(cell["tmax_sum"]) + tmax
		if not is_nan(tmin):
			cell["tmin_sum"] = float(cell["tmin_sum"]) + tmin
		if not is_nan(prec):
			cell["prec_sum"] = float(cell["prec_sum"]) + prec
		cell["count"] = int(cell["count"]) + 1

	if agg.is_empty():
		return false

	# Convert sums → monthly means.
	var new_monthly: Dictionary = {}
	for yr in agg.keys():
		new_monthly[yr] = {}
		for mo in (agg[yr] as Dictionary).keys():
			var cell := (agg[yr] as Dictionary)[mo] as Dictionary
			var cnt := float(int(cell.get("count", 0)))
			if cnt <= 0.0:
				continue
			(new_monthly[yr] as Dictionary)[mo] = {
				"temp_max": float(cell.get("tmax_sum", 0.0)) / cnt,
				"temp_min": float(cell.get("tmin_sum", 0.0)) / cnt,
				"precip":   float(cell.get("prec_sum", 0.0)) / cnt,
			}

	# Compute 1991–2020 baseline from the same dataset.
	var base_sums:   Dictionary = {}
	var base_counts: Dictionary = {}
	for yr in new_monthly.keys():
		if int(yr) < BASELINE_START or int(yr) > BASELINE_END:
			continue
		for mo in (new_monthly[yr] as Dictionary).keys():
			var mm := (new_monthly[yr] as Dictionary)[mo] as Dictionary
			if not base_sums.has(mo):
				base_sums[mo]   = {"temp_max": 0.0, "temp_min": 0.0, "precip": 0.0}
				base_counts[mo] = 0
			var bs := base_sums[mo] as Dictionary
			bs["temp_max"] = float(bs["temp_max"]) + float(mm.get("temp_max", 0.0))
			bs["temp_min"] = float(bs["temp_min"]) + float(mm.get("temp_min", 0.0))
			bs["precip"]   = float(bs["precip"])   + float(mm.get("precip",   0.0))
			base_counts[mo] = int(base_counts.get(mo, 0)) + 1

	if base_sums.is_empty():
		return false
	var new_baseline: Dictionary = {}
	for mo in base_sums.keys():
		var n := float(int(base_counts.get(mo, 0)))
		if n <= 0.0:
			continue
		var s := base_sums[mo] as Dictionary
		new_baseline[mo] = {
			"temp_max": float(s.get("temp_max", 0.0)) / n,
			"temp_min": float(s.get("temp_min", 0.0)) / n,
			"precip":   float(s.get("precip",   0.0)) / n,
		}

	_monthly  = new_monthly
	_baseline = new_baseline
	return true


# ---------------------------------------------------------------------------
# Cache
# ---------------------------------------------------------------------------

func _cache_path(lat: float, lon: float, scenario: int) -> String:
	return "%s/climate_proj_%d_%.2f_%.2f.json" % [CACHE_DIR, scenario, lat, lon]


func _cds_cache_path(lat: float, lon: float, scenario: int) -> String:
	return "%s/climate_proj_cds_%d_%.2f_%.2f.json" % [CACHE_DIR, scenario, lat, lon]


func _read_cache_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var nbytes := f.get_length()
	if nbytes <= 0 or nbytes > MAX_CACHE_BYTES:
		f.close()
		var global_path := ProjectSettings.globalize_path(path)
		if not global_path.is_empty() and FileAccess.file_exists(path):
			DirAccess.remove_absolute(global_path)
		return ""
	var text := f.get_as_text()
	f.close()
	return text


func _write_cache(lat: float, lon: float, scenario: int) -> void:
	var data := {
		"fetch_year": _current_calendar_year(),
		"scenario":   scenario,
		"monthly":    _monthly,
		"baseline":   _baseline,
	}
	var f := FileAccess.open(_cache_path(lat, lon, scenario), FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(data))
	f.close()


func _load_cache(text: String) -> bool:
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return false
	var d := parsed as Dictionary
	if int(d.get("fetch_year", 0)) < _current_calendar_year():
		return false  # stale — refetch annually
	if int(d.get("scenario", -1)) != active_scenario:
		return false  # wrong scenario
	var m: Variant = d.get("monthly", null)
	var b: Variant = d.get("baseline", null)
	if not (m is Dictionary) or not (b is Dictionary):
		return false
	# JSON deserialises all keys as strings; convert year/month keys back to int.
	_monthly  = _rekey_monthly(m as Dictionary)
	_baseline = _rekey_baseline(b as Dictionary)
	return not _monthly.is_empty() and not _baseline.is_empty()


func _rekey_monthly(raw: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for yr_s in raw.keys():
		var yr := int(str(yr_s))
		var mo_dict: Dictionary = {}
		for mo_s in (raw[yr_s] as Dictionary).keys():
			mo_dict[int(str(mo_s))] = (raw[yr_s] as Dictionary)[mo_s]
		out[yr] = mo_dict
	return out


func _rekey_baseline(raw: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for mo_s in raw.keys():
		out[int(str(mo_s))] = raw[mo_s]
	return out


# ---------------------------------------------------------------------------
# Prefs and key helpers
# ---------------------------------------------------------------------------

func _load_prefs() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PREFS_PATH) == OK:
		active_scenario = clampi(int(cfg.get_value("scenario", "selected", Scenario.MODERATE)), 0, 3)


func _save_prefs() -> void:
	var cfg := ConfigFile.new()
	cfg.load(PREFS_PATH)
	cfg.set_value("scenario", "selected", active_scenario)
	cfg.save(PREFS_PATH)


func _read_key(path: String, section: String, key: String) -> String:
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		return ""
	var raw := str(cfg.get_value(section, key, ""))
	if section == "copernicus" and key == "api_key":
		return _normalize_cds_key_from_cfg(raw)
	return raw.strip_edges()


static func _normalize_cds_key_from_cfg(raw: String) -> String:
	var text := raw.replace("\r", "").strip_edges()
	if text.is_empty():
		return ""
	for line in text.split("\n", false):
		var t := line.strip_edges()
		if t.is_empty():
			continue
		var lower := t.to_lower()
		if lower.begins_with("url:"):
			continue
		if lower.begins_with("key:"):
			return t.substr(4).strip_edges()
		return t
	return text


static func _current_calendar_year() -> int:
	return int(Time.get_date_dict_from_system().year)
