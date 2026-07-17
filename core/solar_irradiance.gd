class_name SolarIrradiance
extends RefCounted

## Pure horizontal irradiance (GHI) and PAR helpers for the solar PBI and SolarUI.
## Sun position: Meeus Ch.25 via SolarPosition; clear-sky DNI uses Kasten-Young
## air mass + multi-t transmittance (same model as SolarUI); measured GHI from
## WeatherService when supplied in the weather dict.

const SOLAR_CONSTANT := 1361.0
const STC_IRRADIANCE := 1000.0
const PAR_FRACTION := 0.45
const HORIZON_CUTOFF_DEG := -2.0


static func ghi_wm2(lat_deg: float, lon_deg: float, abs_hours: float,
		weather: Dictionary = {}) -> float:
	var clk := CelestialClock.new()
	clk.latitude = lat_deg
	clk.longitude = lon_deg
	var dd: Dictionary = clk.abs_hours_to_date(abs_hours)
	return ghi_wm2_at_calendar(lat_deg, lon_deg,
		int(dd.get("month", 6)), int(dd.get("day", 15)), float(dd.get("day_time", 12.0)),
		weather, int(dd.get("year", 2026)))


static func ghi_wm2_at_calendar(lat_deg: float, lon_deg: float, month: int, day: int,
		hour: float, weather: Dictionary = {}, year: int = 2026) -> float:
	var clk := CelestialClock.new()
	clk.latitude = lat_deg
	clk.longitude = lon_deg
	var jd_utc: float = clk._julian_day_utc_for(year, month, day, hour)
	var sp := SolarPosition.get_position(lat_deg, lon_deg, jd_utc)
	var el: float = float(sp.get("elevation_deg", 0.0))
	if el < HORIZON_CUTOFF_DEG:
		return 0.0
	if bool(weather.get("has_real", false)):
		var ghi: float = float(weather.get("ghi", 0.0))
		if ghi > 0.0:
			return clampf(ghi, 0.0, 1400.0)
	var cloud: float = clampf(float(weather.get("cloud", 0.0)), 0.0, 1.0)
	return _clear_sky_ghi_wm2(el, cloud)


static func par_wm2_from_ghi(ghi_wm2: float) -> float:
	return maxf(0.0, ghi_wm2) * PAR_FRACTION


static func par_wm2(lat_deg: float, lon_deg: float, abs_hours: float,
		weather: Dictionary = {}) -> float:
	return par_wm2_from_ghi(ghi_wm2(lat_deg, lon_deg, abs_hours, weather))


static func flux_kw_from_ghi(ghi_wm2: float, area_m2: float) -> float:
	return maxf(0.0, ghi_wm2) * maxf(0.0, area_m2) / 1000.0


static func sun_availability(ghi_wm2: float) -> float:
	return clampf(ghi_wm2 / STC_IRRADIANCE, 0.0, 1.2)


## Shared PBI node subtitle string, e.g. "640 W/m² · 80 kW" or "0 W/m²".
## Kept in one place so the live sim tick (resource_flow_engine) and the
## always-on paused-display tick (system_graph_view) never drift apart.
static func pbi_display_string(ghi_wm2: float, flux_kw: float) -> String:
	if ghi_wm2 <= 1.0:
		return "0 W/m²"
	var flux_str: String
	if flux_kw >= 1000.0:
		flux_str = "%.1f MW" % (flux_kw / 1000.0)
	else:
		flux_str = "%.0f kW" % flux_kw
	return "%.0f W/m² · %s" % [ghi_wm2, flux_str]


static func sample_weather(lat_deg: float, lon_deg: float, month: int, day: int,
		hour: float, ws: Node = null) -> Dictionary:
	var out := {"ghi": 0.0, "cloud": 0.0, "temp": 25.0, "has_real": false}
	if ws == null:
		return out
	if not ws.has_method("covers") or not bool(ws.call("covers", lat_deg, lon_deg)):
		return out
	var cover: float = float(ws.call("cloud_cover_frac", month, day, hour))
	if not is_nan(cover):
		out["cloud"] = clampf(cover, 0.0, 1.0)
	var rad: float = float(ws.call("solar_radiation_wm2", month, day, hour))
	if not is_nan(rad) and rad > 1.0:
		out["ghi"] = rad
		out["has_real"] = true
	if ws.has_method("temperature_c"):
		var t: float = float(ws.call("temperature_c", month, day, hour))
		if not is_nan(t):
			out["temp"] = t
	return out


static func dni_clear_sky_wm2(sun_elevation_deg: float) -> float:
	if sun_elevation_deg <= 0.0:
		var twilight: float = maxf(0.0, (sun_elevation_deg + 2.0) / 2.0)
		return 50.0 * twilight
	var zenith_deg: float = 90.0 - sun_elevation_deg
	var zenith_rad: float = deg_to_rad(zenith_deg)
	var air_mass: float = 1.0 / (cos(zenith_rad) + 0.50572 * pow(96.07995 - zenith_deg, -1.6364))
	air_mass = clampf(air_mass, 1.0, 38.0)
	var tau_r: float = exp(-0.0903 * pow(air_mass, 0.84))
	var tau_a: float = exp(-0.12 * pow(air_mass, 0.75))
	var tau_o: float = exp(-0.0127 * pow(air_mass, 0.26))
	var tau_w: float = exp(-0.009 * pow(air_mass, 0.75))
	return SOLAR_CONSTANT * tau_r * tau_a * tau_o * tau_w


static func dhi_clear_sky_wm2(sun_elevation_deg: float, dni: float) -> float:
	if sun_elevation_deg <= 0.0:
		return 20.0 * maxf(0.0, (sun_elevation_deg + 5.0) / 5.0)
	var sin_el: float = sin(deg_to_rad(sun_elevation_deg))
	var clearness: float = 0.85
	var diffuse_frac: float = 0.12 + 0.08 * (1.0 - clearness)
	var ghi_est: float = dni * sin_el
	var dhi: float = ghi_est * diffuse_frac
	return maxf(dhi, 30.0 * sin_el)


static func _clear_sky_ghi_wm2(sun_el_deg: float, cloud_frac: float) -> float:
	if sun_el_deg < HORIZON_CUTOFF_DEG:
		return 0.0
	var dni: float = dni_clear_sky_wm2(sun_el_deg)
	var dhi: float = dhi_clear_sky_wm2(sun_el_deg, dni)
	var sin_el: float = sin(deg_to_rad(sun_el_deg))
	var ghi: float = dni * sin_el + dhi
	if cloud_frac > 0.0:
		ghi *= 1.0 - cloud_frac * 0.5
	return clampf(ghi, 0.0, 1400.0)
