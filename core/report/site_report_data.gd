class_name SiteReportData
extends RefCounted

## Typed container for a computed Site Report (one representative year of
## year-round + month-by-month site analysis). Produced by SiteReportBuilder,
## rendered by SiteReportPanel, and round-tripped to disk as JSON so re-opening
## the same site/graph is instant.
##
## All monthly arrays are length 12 (Jan..Dec). NaN means "no data for that
## month" (e.g. offline with no weather coverage).

const VERSION := 1

# --- Provenance / identity ---
var version: int = VERSION
var generated_unix: int = 0
var site_label: String = ""
var latitude: float = 0.0
var longitude: float = 0.0
var year: int = 0            # effective (representative) weather year computed
var sim_year: int = 0        # sim year the report was requested for
var capacity_signature: String = ""   # invalidates cache on graph/site change
var weather_source: String = "synthetic"  # archive | generated | synthetic
var has_weather: bool = false

# --- Sphere of Influence ---
var soi_radius_m: float = 0.0
var soi_area_m2: float = 0.0

# --- Solar radiation resource (hardware-independent, from hourly GHI) ---
var ghi_climatology_kwh_m2_day: float = 0.0   # GhiService annual-mean band
var ghi_zone_id: int = 0
var ghi_zone_label: String = ""
var solar_monthly_kwh_m2: PackedFloat32Array = PackedFloat32Array()
var solar_annual_kwh_m2: float = 0.0
var solar_peak_sun_hours: float = 0.0         # daily average

# --- PV potential (current system graph) ---
var pv_peak_kw: float = 0.0
var pv_panel_count: int = 0
var pv_panel_tilt_deg: float = 0.0
var pv_panel_azimuth_deg: float = 180.0
var pv_monthly_kwh: PackedFloat32Array = PackedFloat32Array()
var pv_annual_kwh: float = 0.0
var pv_capacity_factor: float = 0.0

# --- Wind resource + potential ---
var wind_turbine_count: int = 0
var wind_rated_kw: float = 0.0
var wind_mean_speed_ms: float = 0.0
var wind_monthly_mean_ms: PackedFloat32Array = PackedFloat32Array()
var wind_monthly_kwh: PackedFloat32Array = PackedFloat32Array()
var wind_annual_kwh: float = 0.0
var wind_capacity_factor: float = 0.0
# Windrose (default 16 sectors, from N clockwise)
var windrose_sectors: int = 16
var windrose_freq: PackedFloat32Array = PackedFloat32Array()      # fraction of hours
var windrose_mean_ms: PackedFloat32Array = PackedFloat32Array()   # mean speed per sector
var windrose_energy: PackedFloat32Array = PackedFloat32Array()    # fraction of Σv³

# --- Hydro potential (current system graph) ---
var hydro_count: int = 0
var hydro_monthly_kwh: PackedFloat32Array = PackedFloat32Array()
var hydro_annual_kwh: float = 0.0

# --- Precipitation / rainflow ---
var precip_monthly_mm: PackedFloat32Array = PackedFloat32Array()
var precip_annual_mm: float = 0.0
var precip_wet_days: PackedInt32Array = PackedInt32Array()
var precip_wet_days_total: int = 0

# --- Temperature ---
var temp_monthly_mean_c: PackedFloat32Array = PackedFloat32Array()
var temp_monthly_min_c: PackedFloat32Array = PackedFloat32Array()
var temp_monthly_max_c: PackedFloat32Array = PackedFloat32Array()
var temp_annual_mean_c: float = 0.0
var temp_annual_min_c: float = 0.0
var temp_annual_max_c: float = 0.0


func _init() -> void:
	solar_monthly_kwh_m2 = _zeros12()
	pv_monthly_kwh = _zeros12()
	wind_monthly_mean_ms = _zeros12()
	wind_monthly_kwh = _zeros12()
	hydro_monthly_kwh = _zeros12()
	precip_monthly_mm = _zeros12()
	temp_monthly_mean_c = _zeros12()
	temp_monthly_min_c = _zeros12()
	temp_monthly_max_c = _zeros12()
	precip_wet_days = _zeros12i()
	windrose_freq = _zerosN(windrose_sectors)
	windrose_mean_ms = _zerosN(windrose_sectors)
	windrose_energy = _zerosN(windrose_sectors)


static func _zeros12() -> PackedFloat32Array:
	return _zerosN(12)


static func _zerosN(n: int) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(maxi(n, 0))
	a.fill(0.0)
	return a


static func _zeros12i() -> PackedInt32Array:
	var a := PackedInt32Array()
	a.resize(12)
	a.fill(0)
	return a


# ---------------------------------------------------------------------------
# Serialization
# ---------------------------------------------------------------------------

func to_dict() -> Dictionary:
	return {
		"version": version,
		"generated_unix": generated_unix,
		"site_label": site_label,
		"latitude": latitude,
		"longitude": longitude,
		"year": year,
		"sim_year": sim_year,
		"capacity_signature": capacity_signature,
		"weather_source": weather_source,
		"has_weather": has_weather,
		"soi_radius_m": soi_radius_m,
		"soi_area_m2": soi_area_m2,
		"ghi_climatology_kwh_m2_day": ghi_climatology_kwh_m2_day,
		"ghi_zone_id": ghi_zone_id,
		"ghi_zone_label": ghi_zone_label,
		"solar_monthly_kwh_m2": Array(solar_monthly_kwh_m2),
		"solar_annual_kwh_m2": solar_annual_kwh_m2,
		"solar_peak_sun_hours": solar_peak_sun_hours,
		"pv_peak_kw": pv_peak_kw,
		"pv_panel_count": pv_panel_count,
		"pv_panel_tilt_deg": pv_panel_tilt_deg,
		"pv_panel_azimuth_deg": pv_panel_azimuth_deg,
		"pv_monthly_kwh": Array(pv_monthly_kwh),
		"pv_annual_kwh": pv_annual_kwh,
		"pv_capacity_factor": pv_capacity_factor,
		"wind_turbine_count": wind_turbine_count,
		"wind_rated_kw": wind_rated_kw,
		"wind_mean_speed_ms": wind_mean_speed_ms,
		"wind_monthly_mean_ms": Array(wind_monthly_mean_ms),
		"wind_monthly_kwh": Array(wind_monthly_kwh),
		"wind_annual_kwh": wind_annual_kwh,
		"wind_capacity_factor": wind_capacity_factor,
		"windrose_sectors": windrose_sectors,
		"windrose_freq": Array(windrose_freq),
		"windrose_mean_ms": Array(windrose_mean_ms),
		"windrose_energy": Array(windrose_energy),
		"hydro_count": hydro_count,
		"hydro_monthly_kwh": Array(hydro_monthly_kwh),
		"hydro_annual_kwh": hydro_annual_kwh,
		"precip_monthly_mm": Array(precip_monthly_mm),
		"precip_annual_mm": precip_annual_mm,
		"precip_wet_days": Array(precip_wet_days),
		"precip_wet_days_total": precip_wet_days_total,
		"temp_monthly_mean_c": Array(temp_monthly_mean_c),
		"temp_monthly_min_c": Array(temp_monthly_min_c),
		"temp_monthly_max_c": Array(temp_monthly_max_c),
		"temp_annual_mean_c": temp_annual_mean_c,
		"temp_annual_min_c": temp_annual_min_c,
		"temp_annual_max_c": temp_annual_max_c,
	}


static func from_dict(d: Dictionary) -> SiteReportData:
	var r := SiteReportData.new()
	r.version = int(d.get("version", VERSION))
	r.generated_unix = int(d.get("generated_unix", 0))
	r.site_label = str(d.get("site_label", ""))
	r.latitude = float(d.get("latitude", 0.0))
	r.longitude = float(d.get("longitude", 0.0))
	r.year = int(d.get("year", 0))
	r.sim_year = int(d.get("sim_year", 0))
	r.capacity_signature = str(d.get("capacity_signature", ""))
	r.weather_source = str(d.get("weather_source", "synthetic"))
	r.has_weather = bool(d.get("has_weather", false))
	r.soi_radius_m = float(d.get("soi_radius_m", 0.0))
	r.soi_area_m2 = float(d.get("soi_area_m2", 0.0))
	r.ghi_climatology_kwh_m2_day = float(d.get("ghi_climatology_kwh_m2_day", 0.0))
	r.ghi_zone_id = int(d.get("ghi_zone_id", 0))
	r.ghi_zone_label = str(d.get("ghi_zone_label", ""))
	r.solar_monthly_kwh_m2 = _to_f32(d.get("solar_monthly_kwh_m2", []))
	r.solar_annual_kwh_m2 = float(d.get("solar_annual_kwh_m2", 0.0))
	r.solar_peak_sun_hours = float(d.get("solar_peak_sun_hours", 0.0))
	r.pv_peak_kw = float(d.get("pv_peak_kw", 0.0))
	r.pv_panel_count = int(d.get("pv_panel_count", 0))
	r.pv_panel_tilt_deg = float(d.get("pv_panel_tilt_deg", 0.0))
	r.pv_panel_azimuth_deg = float(d.get("pv_panel_azimuth_deg", 180.0))
	r.pv_monthly_kwh = _to_f32(d.get("pv_monthly_kwh", []))
	r.pv_annual_kwh = float(d.get("pv_annual_kwh", 0.0))
	r.pv_capacity_factor = float(d.get("pv_capacity_factor", 0.0))
	r.wind_turbine_count = int(d.get("wind_turbine_count", 0))
	r.wind_rated_kw = float(d.get("wind_rated_kw", 0.0))
	r.wind_mean_speed_ms = float(d.get("wind_mean_speed_ms", 0.0))
	r.wind_monthly_mean_ms = _to_f32(d.get("wind_monthly_mean_ms", []))
	r.wind_monthly_kwh = _to_f32(d.get("wind_monthly_kwh", []))
	r.wind_annual_kwh = float(d.get("wind_annual_kwh", 0.0))
	r.wind_capacity_factor = float(d.get("wind_capacity_factor", 0.0))
	r.windrose_sectors = int(d.get("windrose_sectors", 16))
	r.windrose_freq = _to_f32(d.get("windrose_freq", []))
	r.windrose_mean_ms = _to_f32(d.get("windrose_mean_ms", []))
	r.windrose_energy = _to_f32(d.get("windrose_energy", []))
	r.hydro_count = int(d.get("hydro_count", 0))
	r.hydro_monthly_kwh = _to_f32(d.get("hydro_monthly_kwh", []))
	r.hydro_annual_kwh = float(d.get("hydro_annual_kwh", 0.0))
	r.precip_monthly_mm = _to_f32(d.get("precip_monthly_mm", []))
	r.precip_annual_mm = float(d.get("precip_annual_mm", 0.0))
	r.precip_wet_days = _to_i32(d.get("precip_wet_days", []))
	r.precip_wet_days_total = int(d.get("precip_wet_days_total", 0))
	r.temp_monthly_mean_c = _to_f32(d.get("temp_monthly_mean_c", []))
	r.temp_monthly_min_c = _to_f32(d.get("temp_monthly_min_c", []))
	r.temp_monthly_max_c = _to_f32(d.get("temp_monthly_max_c", []))
	r.temp_annual_mean_c = float(d.get("temp_annual_mean_c", 0.0))
	r.temp_annual_min_c = float(d.get("temp_annual_min_c", 0.0))
	r.temp_annual_max_c = float(d.get("temp_annual_max_c", 0.0))
	return r


static func _to_f32(v: Variant) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if v is Array:
		for x in (v as Array):
			out.append(float(x))
	elif v is PackedFloat32Array:
		out = (v as PackedFloat32Array).duplicate()
	return out


static func _to_i32(v: Variant) -> PackedInt32Array:
	var out := PackedInt32Array()
	if v is Array:
		for x in (v as Array):
			out.append(int(x))
	elif v is PackedInt32Array:
		out = (v as PackedInt32Array).duplicate()
	return out
