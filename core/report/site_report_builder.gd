class_name SiteReportBuilder
extends Node

## Async, chunked compute engine for the Site Report.
##
## Runs a full representative year (8760 hours) of site analysis a bounded number
## of days per frame so the UI stays responsive and can show progress — the same
## chunk-per-frame pattern as core/batch_renderer.gd. It samples WeatherService
## for radiation/wind/precip/temperature and reuses SolarUI.evaluate_solar_at()
## (a pure function of absolute time) for PV yield, so the report reflects the
## same physics + graph-synced capacity the sim uses.
##
## Results are written to a SiteReportData and cached to disk keyed by a
## capacity signature (site + graph + year), so re-opening an unchanged report is
## instant.

signal progress(frac: float)
signal report_ready(data: SiteReportData)

const CACHE_DIR := "user://site_reports/"
const CACHE_VERSION := 1
## Days computed per frame. 365 days / 20 ≈ 19 frames; each day = 24 h of
## sampling + PV eval, comfortably under a frame budget.
const DAYS_PER_CHUNK := 20
const WINDROSE_SECTORS := 16

var _active: bool = false
var _day: int = 0

var _main: Node = null
var _solar_ui: Node = null
var _weather: Node = null
var _lat: float = 0.0
var _lon: float = 0.0
var _year: int = 0
var _sim_year: int = 0

# Collected hourly series (8760).
var _ghi := PackedFloat32Array()
var _pv := PackedFloat32Array()
var _precip := PackedFloat32Array()
var _temp := PackedFloat32Array()
var _wind_ms := PackedFloat32Array()
var _wind_dir := PackedFloat32Array()
var _wind_kw := PackedFloat32Array()

var _wind_specs: Array = []
var _hydro_specs: Array = []
var _wind_rated_kw: float = 0.0

var _data: SiteReportData = null


func _ready() -> void:
	set_process(false)


func is_building() -> bool:
	return _active


func get_progress() -> float:
	if not _active:
		return 1.0
	return clampf(float(_day) / float(SiteReportMetrics.DAYS_PER_YEAR), 0.0, 1.0)


func cancel() -> void:
	_active = false
	set_process(false)


# ---------------------------------------------------------------------------
# Start / configuration
# ---------------------------------------------------------------------------

## Kick off a build. `main` supplies latitude/longitude/clock; `solar_ui` the PV
## evaluator + installed capacity; `model` (a GraphModel) the wind/hydro items.
func start(main: Node, solar_ui: Node, model: Object, sim_year: int,
		site_label: String, soi_radius_m: float, soi_area_m2: float) -> void:
	cancel()
	_main = main
	_solar_ui = solar_ui
	_weather = get_node_or_null("/root/WeatherService")
	_lat = float(main.get("latitude")) if main != null and main.get("latitude") != null else 0.0
	_lon = float(main.get("longitude")) if main != null and main.get("longitude") != null else 0.0
	_sim_year = sim_year
	_year = int(WeatherService.effective_year(sim_year)) if _weather != null else sim_year

	_data = SiteReportData.new()
	_data.generated_unix = int(Time.get_unix_time_from_system())
	_data.site_label = site_label
	_data.latitude = _lat
	_data.longitude = _lon
	_data.year = _year
	_data.sim_year = sim_year
	_data.soi_radius_m = soi_radius_m
	_data.soi_area_m2 = soi_area_m2
	_data.windrose_sectors = WINDROSE_SECTORS

	# Installed PV specs (mirrors what SolarUI uses for evaluate_solar_at).
	_data.pv_peak_kw = _get_num(solar_ui, "PEAK_CAPACITY_KW", 0.0)
	_data.pv_panel_count = int(_get_num(solar_ui, "PANEL_COUNT", 0.0))
	_data.pv_panel_tilt_deg = _get_num(solar_ui, "panel_tilt_degrees", 0.0)
	_data.pv_panel_azimuth_deg = _get_num(solar_ui, "panel_azimuth_degrees", 180.0)

	# Enumerate wind + hydro items in the root scope of the graph.
	_wind_specs.clear()
	_hydro_specs.clear()
	_wind_rated_kw = 0.0
	if model != null and model.has_method("get_items_in_scope"):
		for item: Dictionary in model.get_items_in_scope("root"):
			if bool(item.get("is_virtual", false)):
				continue
			var ty := str(item.get("type", ""))
			var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
			if ty == "wind":
				_wind_specs.append(specs)
				_wind_rated_kw += maxf(float(specs.get("rated_w", 1000.0)), 0.0) / 1000.0
			elif ty == "hydro":
				_hydro_specs.append(specs)
	_data.wind_turbine_count = _wind_specs.size()
	_data.wind_rated_kw = _wind_rated_kw
	_data.hydro_count = _hydro_specs.size()

	# GHI climatology band (hardware-independent headline resource).
	var ghi_svc := get_node_or_null("/root/GhiService")
	if ghi_svc != null and ghi_svc.has_method("ghi_kwh_per_m2_day"):
		var g := float(ghi_svc.call("ghi_kwh_per_m2_day", _lat, _lon))
		_data.ghi_climatology_kwh_m2_day = g
		if ghi_svc.has_method("get_zone"):
			var z: Dictionary = ghi_svc.call("get_zone", g)
			_data.ghi_zone_id = int(z.get("id", 0))
			_data.ghi_zone_label = str(z.get("label", ""))

	# Weather provenance.
	var covers := _weather != null and _weather.has_method("covers") \
		and bool(_weather.call("covers", _lat, _lon))
	_data.has_weather = covers
	if covers:
		_data.weather_source = "generated" if (_weather.has_method("is_generated_year") \
			and bool(_weather.call("is_generated_year", _year))) else "archive"
	else:
		_data.weather_source = "synthetic"

	_data.capacity_signature = _compute_signature()

	# Allocate hourly buffers.
	var n := SiteReportMetrics.HOURS_PER_YEAR
	_ghi = _alloc(n)
	_pv = _alloc(n)
	_precip = _alloc(n)
	_temp = _alloc(n)
	_wind_ms = _alloc(n)
	_wind_dir = _alloc(n)
	_wind_kw = _alloc(n)

	_day = 0
	_active = true
	set_process(true)
	progress.emit(0.0)


func _alloc(n: int) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(n)
	a.fill(NAN)
	return a


# ---------------------------------------------------------------------------
# Chunked compute
# ---------------------------------------------------------------------------

func _process(_delta: float) -> void:
	if not _active:
		set_process(false)
		return
	var end_day := mini(_day + DAYS_PER_CHUNK, SiteReportMetrics.DAYS_PER_YEAR)
	while _day < end_day:
		_compute_day(_day)
		_day += 1
	progress.emit(get_progress())
	if _day >= SiteReportMetrics.DAYS_PER_YEAR:
		_active = false
		set_process(false)
		_finalize()


func _compute_day(doy: int) -> void:
	var md := SiteReportMetrics.month_day_from_doy(doy)
	var m := md.x
	var d := md.y
	var has_ws := _data.has_weather and _weather != null
	for h in range(24):
		var idx := doy * 24 + h
		var hf := float(h)

		var wspd := NAN
		if has_ws:
			var ghi := float(_weather.call("solar_radiation_wm2", m, d, hf))
			_ghi[idx] = 0.0 if is_nan(ghi) else maxf(ghi, 0.0)
			var t := float(_weather.call("temperature_c", m, d, hf))
			_temp[idx] = t
			var pr := float(_weather.call("rain_rate_mmh", m, d, hf))
			_precip[idx] = 0.0 if is_nan(pr) else maxf(pr, 0.0)
			wspd = float(_weather.call("wind_speed_ms", m, d, hf))
			_wind_ms[idx] = wspd
			_wind_dir[idx] = float(_weather.call("wind_direction_deg", m, d, hf))
		else:
			_ghi[idx] = 0.0
			_precip[idx] = 0.0

		# PV yield via the shared pure evaluator (uses graph-synced capacity).
		var pv := 0.0
		if _solar_ui != null and _solar_ui.has_method("evaluate_solar_at"):
			var abs_h := SiteReportMetrics.date_to_abs_hours(_year, m, d, hf)
			pv = float(_solar_ui.call("evaluate_solar_at", abs_h))
		_pv[idx] = maxf(pv, 0.0)

		# Wind power summed across all graph turbines this hour.
		var wkw := 0.0
		if not _wind_specs.is_empty():
			for specs in _wind_specs:
				wkw += WindTurbineSource.power_kw_from_graph_specs(specs, hf, wspd)
		_wind_kw[idx] = wkw


# ---------------------------------------------------------------------------
# Aggregation
# ---------------------------------------------------------------------------

func _finalize() -> void:
	# --- Solar radiation resource ---
	# GHI is W/m² per hour → Wh/m²; /1000 = kWh/m².
	var ghi_month_wh := SiteReportMetrics.monthly_sum(_ghi)
	for mo in range(12):
		_data.solar_monthly_kwh_m2[mo] = ghi_month_wh[mo] / 1000.0
	_data.solar_annual_kwh_m2 = SiteReportMetrics.annual_sum(_ghi) / 1000.0
	_data.solar_peak_sun_hours = SiteReportMetrics.peak_sun_hours(_data.solar_annual_kwh_m2)

	# --- PV potential ---
	_data.pv_monthly_kwh = SiteReportMetrics.monthly_sum(_pv)
	_data.pv_annual_kwh = SiteReportMetrics.annual_sum(_pv)
	_data.pv_capacity_factor = SiteReportMetrics.capacity_factor(
		_data.pv_annual_kwh, _data.pv_peak_kw)

	# --- Wind ---
	_data.wind_monthly_kwh = SiteReportMetrics.monthly_sum(_wind_kw)
	_data.wind_annual_kwh = SiteReportMetrics.annual_sum(_wind_kw)
	_data.wind_capacity_factor = SiteReportMetrics.capacity_factor(
		_data.wind_annual_kwh, _data.wind_rated_kw)
	_data.wind_monthly_mean_ms = SiteReportMetrics.monthly_mean(_wind_ms)
	var wm := SiteReportMetrics.annual_mean(_wind_ms)
	_data.wind_mean_speed_ms = 0.0 if is_nan(wm) else wm
	_compute_windrose()

	# --- Hydro (monthly closed form, does not need the hourly loop) ---
	if not _hydro_specs.is_empty():
		var mults: Array = []
		if _data.has_weather and _weather != null and _weather.has_method("monthly_precip_multipliers"):
			mults = _weather.call("monthly_precip_multipliers") as Array
		var hydro_annual := 0.0
		for mo in range(12):
			var month := mo + 1
			var kw := 0.0
			for specs in _hydro_specs:
				kw += HydroSource.power_kw_from_graph_specs(specs, month, mults)
			var kwh := kw * float(SiteReportMetrics.hours_in_month(month))
			_data.hydro_monthly_kwh[mo] = kwh
			hydro_annual += kwh
		_data.hydro_annual_kwh = hydro_annual

	# --- Precipitation / rainflow ---
	_data.precip_monthly_mm = SiteReportMetrics.monthly_sum(_precip)
	_data.precip_annual_mm = SiteReportMetrics.annual_sum(_precip)
	_data.precip_wet_days = SiteReportMetrics.monthly_wet_days(_precip)
	var wet_total := 0
	for c in _data.precip_wet_days:
		wet_total += c
	_data.precip_wet_days_total = wet_total

	# --- Temperature ---
	_data.temp_monthly_mean_c = SiteReportMetrics.monthly_mean(_temp)
	_data.temp_monthly_min_c = SiteReportMetrics.monthly_min(_temp)
	_data.temp_monthly_max_c = SiteReportMetrics.monthly_max(_temp)
	var tmean := SiteReportMetrics.annual_mean(_temp)
	_data.temp_annual_mean_c = 0.0 if is_nan(tmean) else tmean
	_data.temp_annual_min_c = _safe_min(_data.temp_monthly_min_c)
	_data.temp_annual_max_c = _safe_max(_data.temp_monthly_max_c)

	save_to_cache(_data)
	# Free the large hourly buffers now that everything is aggregated.
	_ghi = PackedFloat32Array()
	_pv = PackedFloat32Array()
	_precip = PackedFloat32Array()
	_temp = PackedFloat32Array()
	_wind_ms = PackedFloat32Array()
	_wind_dir = PackedFloat32Array()
	_wind_kw = PackedFloat32Array()
	report_ready.emit(_data)


func _compute_windrose() -> void:
	var n := WINDROSE_SECTORS
	var counts := PackedFloat32Array()
	var speed_sum := PackedFloat32Array()
	var energy_sum := PackedFloat32Array()
	counts.resize(n); counts.fill(0.0)
	speed_sum.resize(n); speed_sum.fill(0.0)
	energy_sum.resize(n); energy_sum.fill(0.0)
	var total := 0.0
	var total_energy := 0.0
	for i in range(_wind_ms.size()):
		var spd := _wind_ms[i]
		var dir := _wind_dir[i]
		if is_nan(spd) or is_nan(dir):
			continue
		var s := SiteReportMetrics.windrose_sector_index(dir, n)
		counts[s] += 1.0
		speed_sum[s] += spd
		var e := spd * spd * spd
		energy_sum[s] += e
		total += 1.0
		total_energy += e
	var freq := PackedFloat32Array(); freq.resize(n)
	var meanv := PackedFloat32Array(); meanv.resize(n)
	var energy := PackedFloat32Array(); energy.resize(n)
	for s in range(n):
		freq[s] = counts[s] / total if total > 0.0 else 0.0
		meanv[s] = speed_sum[s] / counts[s] if counts[s] > 0.0 else 0.0
		energy[s] = energy_sum[s] / total_energy if total_energy > 0.0 else 0.0
	_data.windrose_freq = freq
	_data.windrose_mean_ms = meanv
	_data.windrose_energy = energy


# ---------------------------------------------------------------------------
# Cache
# ---------------------------------------------------------------------------

static func cache_path(lat: float, lon: float, year: int) -> String:
	return "%sreport_v%d_%.4f_%.4f_%d.json" % [CACHE_DIR, CACHE_VERSION, lat, lon, year]


## Return a cached report matching `signature`, or null. Recomputes if the graph
## or site changed (signature mismatch) or the file is missing/corrupt.
static func load_cached(lat: float, lon: float, sim_year: int, signature: String) -> SiteReportData:
	var year := int(WeatherService.effective_year(sim_year))
	var path := cache_path(lat, lon, year)
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var txt := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(txt)
	if parsed is not Dictionary:
		return null
	var data := SiteReportData.from_dict(parsed as Dictionary)
	if data.version != SiteReportData.VERSION:
		return null
	if not signature.is_empty() and data.capacity_signature != signature:
		return null
	return data


func save_to_cache(data: SiteReportData) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE_DIR))
	var path := cache_path(data.latitude, data.longitude, data.year)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("SiteReportBuilder: could not write cache %s" % path)
		return
	f.store_string(JSON.stringify(data.to_dict()))
	f.close()


## Deterministic signature over site + installed graph + year. Any change to
## panels/tilt/azimuth/turbines/hydro or the site/year invalidates the cache.
func _compute_signature() -> String:
	var parts := PackedStringArray()
	parts.append("y=%d" % _year)
	parts.append("lat=%.4f" % _lat)
	parts.append("lon=%.4f" % _lon)
	parts.append("pv=%.2f/%d/%.1f/%.1f" % [
		_data.pv_peak_kw, _data.pv_panel_count,
		_data.pv_panel_tilt_deg, _data.pv_panel_azimuth_deg])
	parts.append("wind=%s" % JSON.stringify(_wind_specs))
	parts.append("hydro=%s" % JSON.stringify(_hydro_specs))
	parts.append("wx=%s" % _data.weather_source)
	return "sig%d|%s" % [CACHE_VERSION, "|".join(parts)]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

## Signature for a prospective report WITHOUT running the build — lets the panel
## check the cache before deciding whether to fetch weather + compute.
static func signature_for(main: Node, solar_ui: Node, model: Object, sim_year: int,
		weather_covers: bool, weather_generated: bool) -> String:
	var year := int(WeatherService.effective_year(sim_year))
	var lat := float(main.get("latitude")) if main != null and main.get("latitude") != null else 0.0
	var lon := float(main.get("longitude")) if main != null and main.get("longitude") != null else 0.0
	var peak := _get_num_static(solar_ui, "PEAK_CAPACITY_KW", 0.0)
	var count := int(_get_num_static(solar_ui, "PANEL_COUNT", 0.0))
	var tilt := _get_num_static(solar_ui, "panel_tilt_degrees", 0.0)
	var az := _get_num_static(solar_ui, "panel_azimuth_degrees", 180.0)
	var wind_specs: Array = []
	var hydro_specs: Array = []
	if model != null and model.has_method("get_items_in_scope"):
		for item: Dictionary in model.get_items_in_scope("root"):
			if bool(item.get("is_virtual", false)):
				continue
			var ty := str(item.get("type", ""))
			if ty == "wind":
				wind_specs.append((item.get("specs", {}) as Dictionary).duplicate(true))
			elif ty == "hydro":
				hydro_specs.append((item.get("specs", {}) as Dictionary).duplicate(true))
	var wx := "synthetic"
	if weather_covers:
		wx = "generated" if weather_generated else "archive"
	var parts := PackedStringArray()
	parts.append("y=%d" % year)
	parts.append("lat=%.4f" % lat)
	parts.append("lon=%.4f" % lon)
	parts.append("pv=%.2f/%d/%.1f/%.1f" % [peak, count, tilt, az])
	parts.append("wind=%s" % JSON.stringify(wind_specs))
	parts.append("hydro=%s" % JSON.stringify(hydro_specs))
	parts.append("wx=%s" % wx)
	return "sig%d|%s" % [CACHE_VERSION, "|".join(parts)]


func _get_num(obj: Object, prop: String, dflt: float) -> float:
	return _get_num_static(obj, prop, dflt)


static func _get_num_static(obj: Object, prop: String, dflt: float) -> float:
	if obj == null:
		return dflt
	var v: Variant = obj.get(prop)
	return float(v) if v != null else dflt


func _safe_min(arr: PackedFloat32Array) -> float:
	var lo := INF
	for v in arr:
		if not is_nan(v):
			lo = minf(lo, v)
	return lo if is_finite(lo) else 0.0


func _safe_max(arr: PackedFloat32Array) -> float:
	var hi := -INF
	for v in arr:
		if not is_nan(v):
			hi = maxf(hi, v)
	return hi if is_finite(hi) else 0.0
