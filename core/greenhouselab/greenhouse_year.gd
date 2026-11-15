class_name GreenhouseYear
extends RefCounted

## A greenhouse design's year at a site, hour by hour (the designer's Climate
## tab). Two halves so the long one can run on a worker thread:
##  - `weather_table` (main thread: it may read the WeatherService node) takes
##    a year of hourly outside weather into packed rows; with no weather for
##    the site it makes a SYNTHETIC year from the latitude (`synthetic`, an
##    estimate: a cosine seasonal and daily wave, a fixed humidity, cloud and
##    a rain day in five);
##  - `run` (pure) steps GreenhouseClimate through it with the built-in
##    controller and GreenhouseCrops a day at a time, and sums it by month.
## The sun is SolarPosition (Meeus) at each hour; GHI is the measured value
## where there is real weather, else the clear-sky model under the cloud.

const COLS := 7   # t, rh, wind, ghi, cloud, rain, has_real
const DAYS_IN_MONTH := [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
const DEFAULT_YEAR := 2025
## The synthetic year (estimates).
const SYN_RH := 65.0
const SYN_WIND := 3.0
const SYN_CLOUD := 0.35
const SYN_DAY_AMP := 5.5
const SYN_RAIN_EVERY := 5
const SYN_RAIN_MMH := 2.0


static func month_day(doy0: int) -> Vector2i:
	var d := doy0
	for m in 12:
		var n: int = DAYS_IN_MONTH[m]
		if d < n:
			return Vector2i(m + 1, d + 1)
		d -= n
	return Vector2i(12, 31)


## Synthetic weather at day-of-year (0-based) and hour.
static func synthetic(lat: float, doy0: int, hour: float) -> Dictionary:
	var a := absf(lat)
	var t_ann := 27.0 - 0.42 * maxf(a - 10.0, 0.0) - 0.004 * maxf(a - 10.0, 0.0) * maxf(a - 10.0, 0.0)
	var amp := clampf(0.33 * a - 2.0, 1.0, 20.0)
	var coldest := 15.0 if lat >= 0.0 else 197.0
	var t_day := t_ann - amp * cos(TAU * (float(doy0) - coldest) / 365.0)
	var t := t_day + SYN_DAY_AMP * cos(TAU * (hour - 15.0) / 24.0)
	var rain := SYN_RAIN_MMH if (doy0 % SYN_RAIN_EVERY == 2 and hour >= 13.0 and hour < 16.0) else 0.0
	var cloud := 0.85 if doy0 % SYN_RAIN_EVERY == 2 else SYN_CLOUD
	return {"t": t, "rh": SYN_RH + (20.0 if rain > 0.0 else 0.0), "wind": SYN_WIND, "cloud": cloud, "rain": rain}


## A year of hourly weather: {data: PackedFloat32Array (8760 × COLS),
## monthly_c: [12], real: bool, year}. `ws` is the WeatherService node (or
## null); it is used only when it has data covering the site.
static func weather_table(lat: float, lon: float, ws: Object = null, year: int = DEFAULT_YEAR) -> Dictionary:
	var real := false
	if ws != null and ws.has_method("has_data") and bool(ws.call("has_data")) \
			and ws.has_method("covers") and bool(ws.call("covers", lat, lon)):
		real = true
	var data := PackedFloat32Array()
	data.resize(365 * 24 * COLS)
	var msum := []
	var mn := []
	for i in 12:
		msum.append(0.0)
		mn.append(0)
	for d in 365:
		var md := month_day(d)
		for h in 24:
			var hr := float(h) + 0.5
			var row := {}
			if real:
				row = {"t": float(ws.call("temperature_c", md.x, md.y, hr)), "rh": float(ws.call("humidity_pct", md.x, md.y, hr)),
					"wind": float(ws.call("wind_speed_ms", md.x, md.y, hr)), "cloud": float(ws.call("cloud_cover_frac", md.x, md.y, hr)),
					"rain": float(ws.call("rain_rate_mmh", md.x, md.y, hr)), "ghi": float(ws.call("solar_radiation_wm2", md.x, md.y, hr))}
				var syn := synthetic(lat, d, hr)
				for k in ["t", "rh", "wind", "cloud", "rain"]:
					if not is_finite(float(row[k])):
						row[k] = syn[k]
			else:
				row = synthetic(lat, d, hr)
				row["ghi"] = -1.0
			var i0 := (d * 24 + h) * COLS
			data[i0] = float(row["t"])
			data[i0 + 1] = clampf(float(row["rh"]), 1.0, 100.0)
			data[i0 + 2] = maxf(float(row["wind"]), 0.0)
			data[i0 + 3] = float(row["ghi"]) if is_finite(float(row["ghi"])) else -1.0
			data[i0 + 4] = clampf(float(row["cloud"]), 0.0, 1.0)
			data[i0 + 5] = maxf(float(row["rain"]), 0.0)
			data[i0 + 6] = 1.0 if real and float(row["ghi"]) >= 0.0 else 0.0
			msum[md.x - 1] = float(msum[md.x - 1]) + float(row["t"])
			mn[md.x - 1] = int(mn[md.x - 1]) + 1
	var monthly: Array = []
	for i in 12:
		monthly.append(float(msum[i]) / maxf(float(mn[i]), 1.0))
	return {"data": data, "monthly_c": monthly, "real": real, "year": year, "lat": lat, "lon": lon}


## The year. opts: {yaw_deg, days (365; fewer for a quick look), dt_h (1.0),
## cancel: Callable() -> bool, progress: Callable(frac)}. Pure.
static func run(d: Dictionary, tbl: Dictionary, opts: Dictionary = {}) -> Dictionary:
	var lat := float(tbl.get("lat", 45.0))
	var lon := float(tbl.get("lon", 0.0))
	var year := int(tbl.get("year", DEFAULT_YEAR))
	var data: PackedFloat32Array = tbl["data"]
	var m := GreenhouseClimate.model(d, {"yaw_deg": float(opts.get("yaw_deg", 0.0)), "monthly_c": tbl["monthly_c"]})
	var days := clampi(int(opts.get("days", 365)), 1, 365)
	var dt := clampf(float(opts.get("dt_h", 1.0)), 0.25, 2.0)
	var clk := CelestialClock.new()
	clk.latitude = lat
	clk.longitude = lon
	var crops := GreenhouseCrops.new_state(d)
	var mon := _new_months()
	var daily := {"in_min": PackedFloat32Array(), "in_max": PackedFloat32Array(),
		"out_min": PackedFloat32Array(), "out_max": PackedFloat32Array(), "dli": PackedFloat32Array(),
		"rh_max": PackedFloat32Array()}
	var w0 := 0
	var st := GreenhouseClimate.initial_state(m, data[0], data[1], 0.0)
	var cancel: Callable = opts.get("cancel", Callable())
	var progress: Callable = opts.get("progress", Callable())
	var steps_per_day := int(round(24.0 / dt))
	for dd in days:
		if cancel.is_valid() and bool(cancel.call()):
			return {"cancelled": true}
		var md := month_day(dd)
		var mi := md.x - 1
		var day_in := [INF, -INF, 0.0]
		var day_out := [INF, -INF]
		var vpd_sum := 0.0
		var rh_max := 0.0
		var dli_sun := 0.0
		var dli_all := 0.0
		for k in steps_per_day:
			var hr := (float(k) + 0.5) * dt
			var hi := clampi(int(hr), 0, 23)
			var i0 := (dd * 24 + hi) * COLS
			var t_out := data[i0]
			var cloud := data[i0 + 4]
			var jd := clk._julian_day_utc_for(year, md.x, md.y, hr)
			var sp := SolarPosition.get_position(lat, lon, jd)
			var el := float(sp.get("elevation_deg", -10.0))
			var real := data[i0 + 6] > 0.5
			var ghi := float(data[i0 + 3]) if real else SolarIrradiance._clear_sky_ghi_wm2(el, cloud, SolarIrradiance.AOD_BASELINE)
			if el < SolarIrradiance.HORIZON_CUTOFF_DEG:
				ghi = 0.0
			var inp := {"t_out": t_out, "rh_out": data[i0 + 1], "wind": data[i0 + 2], "ghi": ghi, "cloud": cloud,
				"sun_az": float(sp.get("azimuth_deg", 180.0)), "sun_el": el, "rain_mmh": data[i0 + 5],
				"doy": float(dd), "hour": hr, "abs_h": float(dd) * 24.0 + hr, "has_real": real,
				"lai": GreenhouseCrops.lai(crops)}
			var o := GreenhouseClimate.step(m, st, inp, dt)
			var ta := float(o["t_air"])
			day_in[0] = minf(day_in[0], ta)
			day_in[1] = maxf(day_in[1], ta)
			day_in[2] = float(day_in[2]) + ta
			day_out[0] = minf(day_out[0], t_out)
			day_out[1] = maxf(day_out[1], t_out)
			vpd_sum += float(o["vpd"])
			rh_max = maxf(rh_max, float(o["rh"]))
			dli_sun += float(o["ppfd_sun"]) * dt * 3600.0 / 1e6
			dli_all += float(o["ppfd"]) * dt * 3600.0 / 1e6
			var mo: Dictionary = mon[mi]
			mo["in_sum"] = float(mo["in_sum"]) + ta
			mo["out_sum"] = float(mo["out_sum"]) + t_out
			mo["n"] = int(mo["n"]) + 1
			if float(o["vent"]) > 0.02:
				mo["vent_h"] = float(mo["vent_h"]) + dt
			if bool(o["fans"]):
				mo["fan_h"] = float(mo["fan_h"]) + dt * float(o["fan_duty"])
			if bool(o["heater"]):
				mo["heater_h"] = float(mo["heater_h"]) + dt * float(o["heater_duty"])
			if bool(o["lights"]):
				mo["lights_h"] = float(mo["lights_h"]) + dt
			mo["lights_kwh"] = float(mo["lights_kwh"]) + float(o["q_lights_w"]) * dt / 1000.0
			mo["power_kwh"] = float(mo["power_kwh"]) + float(o["power_w"]) * dt / 1000.0
			mo["propane_kg"] = float(mo["propane_kg"]) + float(o["propane_kg_h"]) * dt
			mo["rain_l"] = float(mo["rain_l"]) + float(o["rain_lph"]) * dt
			mo["cond_l"] = float(mo["cond_l"]) + float(o["cond_lph"]) * dt
			mo["water_l"] = float(mo["water_l"]) + (float(o["transp_lph"]) + float(o["soil_evap_lph"])) * dt
			if ta > 35.0:
				mo["hot_h"] = float(mo["hot_h"]) + dt
		var mo2: Dictionary = mon[mi]
		mo2["in_min"] = minf(float(mo2["in_min"]), float(day_in[0]))
		mo2["in_max"] = maxf(float(mo2["in_max"]), float(day_in[1]))
		mo2["out_min"] = minf(float(mo2["out_min"]), float(day_out[0]))
		mo2["out_max"] = maxf(float(mo2["out_max"]), float(day_out[1]))
		mo2["dli_sum"] = float(mo2["dli_sum"]) + dli_all
		mo2["days"] = int(mo2["days"]) + 1
		if float(day_in[0]) < 0.0:
			mo2["frost_d"] = int(mo2["frost_d"]) + 1
		var t_mean := float(day_in[2]) / float(steps_per_day)
		var got := GreenhouseCrops.day(crops, {"t_mean": t_mean, "t_min": float(day_in[0]),
			"vpd": vpd_sum / float(steps_per_day), "dli_sun": dli_sun, "dli_lit": dli_all})
		for id in got:
			mo2["yield_kg"] = float(mo2["yield_kg"]) + float(got[id])
		daily["in_min"].append(float(day_in[0]))
		daily["in_max"].append(float(day_in[1]))
		daily["out_min"].append(float(day_out[0]))
		daily["out_max"].append(float(day_out[1]))
		daily["dli"].append(dli_all)
		daily["rh_max"].append(rh_max)
		if progress.is_valid() and dd % 10 == 0:
			progress.call(float(dd) / float(days))
		w0 = dd
	return _finish(mon, daily, crops, st, d, tbl, days)


static func _new_months() -> Array:
	var out: Array = []
	for i in 12:
		out.append({"in_min": INF, "in_max": -INF, "out_min": INF, "out_max": -INF, "in_sum": 0.0, "out_sum": 0.0,
			"n": 0, "days": 0, "vent_h": 0.0, "fan_h": 0.0, "heater_h": 0.0, "lights_h": 0.0, "lights_kwh": 0.0,
			"power_kwh": 0.0, "propane_kg": 0.0, "rain_l": 0.0, "cond_l": 0.0, "water_l": 0.0, "frost_d": 0,
			"dli_sum": 0.0, "yield_kg": 0.0, "hot_h": 0.0})
	return out


static func _finish(mon: Array, daily: Dictionary, crops: Dictionary, st: Dictionary, d: Dictionary,
		tbl: Dictionary, days: int) -> Dictionary:
	var months: Array = []
	var tot := {"vent_h": 0.0, "fan_h": 0.0, "heater_h": 0.0, "lights_h": 0.0, "lights_kwh": 0.0, "power_kwh": 0.0,
		"propane_kg": 0.0, "rain_l": 0.0, "cond_l": 0.0, "water_l": 0.0, "frost_d": 0, "yield_kg": 0.0, "hot_h": 0.0}
	var coldest := INF
	var hottest := -INF
	var out_coldest := INF
	for i in 12:
		var mo: Dictionary = mon[i]
		if int(mo["n"]) == 0:
			continue
		var row := {"month": i + 1, "in_min": mo["in_min"], "in_max": mo["in_max"], "in_mean": float(mo["in_sum"]) / float(mo["n"]),
			"out_min": mo["out_min"], "out_max": mo["out_max"], "out_mean": float(mo["out_sum"]) / float(mo["n"]),
			"dli": float(mo["dli_sum"]) / maxf(float(mo["days"]), 1.0)}
		for k in tot:
			row[k] = mo[k]
			tot[k] = float(tot[k]) + float(mo[k])
		months.append(row)
		coldest = minf(coldest, float(mo["in_min"]))
		hottest = maxf(hottest, float(mo["in_max"]))
		out_coldest = minf(out_coldest, float(mo["out_min"]))
	tot["frost_d"] = int(tot["frost_d"])
	tot["coldest_in"] = coldest
	tot["hottest_in"] = hottest
	tot["coldest_out"] = out_coldest
	tot["harvest"] = (crops["harvest"] as Dictionary).duplicate()
	tot["lost"] = int(crops["lost"])
	tot["cycles"] = int(crops["cycles"])
	var floor_a := float(d["stats"].get("floor_area_m2", 0.0))
	tot["yield_kg_m2"] = float(tot["yield_kg"]) / maxf(float(d["stats"].get("bed_area_m2", floor_a)), 0.01)
	return {"months": months, "daily": daily, "total": tot, "days": days, "real_weather": bool(tbl.get("real", false)),
		"ledger": (st["ledger"] as Dictionary).duplicate(), "condensate_l": float(st["condensate_l"])}
