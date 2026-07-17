class_name AtmospherePbi
extends RefCounted

## Planetary Basic Income — atmosphere over the Sphere of Influence.
## Publishes live weather (wind speed, temperature, relative humidity) plus an
## educational kinetic flux estimate (½ρAv³ through a SoI-wide vertical slab).
## Ambient and non-blocking: turbines and dew harvesters read WeatherService
## directly; optional dashed wires only visualize the link (mirrors sunlight).

const AIR_DENSITY_KG_M3 := 1.225  # ISA sea-level
## Nominal slab height for SoI kinetic estimate (m) — playable order-of-magnitude,
## not a CFD capture area.
const KINETIC_SLAB_HEIGHT_M := 10.0


## Sample atmosphere at a calendar instant. `ws` is WeatherService or null.
## Returns {wind_ms, temp_c, humidity_pct, cloud_frac, rain_mmh, has_real}.
static func sample(lat: float, lon: float, month: int, day: int, hour: float,
		ws: Node = null) -> Dictionary:
	var out := {
		"wind_ms": 0.0,
		"temp_c": 20.0,
		"humidity_pct": 50.0,
		"cloud_frac": 0.0,
		"rain_mmh": 0.0,
		"has_real": false,
	}
	if ws == null:
		return out
	if not ws.has_method("covers") or not bool(ws.call("covers", lat, lon)):
		return out
	out["has_real"] = true
	if ws.has_method("wind_speed_ms"):
		var w: float = float(ws.call("wind_speed_ms", month, day, hour))
		if not is_nan(w):
			out["wind_ms"] = maxf(0.0, w)
	if ws.has_method("temperature_c"):
		var t: float = float(ws.call("temperature_c", month, day, hour))
		if not is_nan(t):
			out["temp_c"] = t
	if ws.has_method("humidity_pct"):
		var h: float = float(ws.call("humidity_pct", month, day, hour))
		if not is_nan(h):
			out["humidity_pct"] = clampf(h, 0.0, 100.0)
	if ws.has_method("cloud_cover_frac"):
		var c: float = float(ws.call("cloud_cover_frac", month, day, hour))
		if not is_nan(c):
			out["cloud_frac"] = clampf(c, 0.0, 1.0)
	if ws.has_method("rain_rate_mmh"):
		var r: float = float(ws.call("rain_rate_mmh", month, day, hour))
		if not is_nan(r):
			out["rain_mmh"] = maxf(0.0, r)
	return out


## Kinetic power through a vertical slab spanning the SoI diameter × height (kW).
## P = ½ ρ A v³ with A = 2·radius · height. Educational — not turbine yield.
static func kinetic_flux_kw(wind_ms: float, soi_area_m2: float) -> float:
	var v := maxf(0.0, wind_ms)
	var area := maxf(0.0, soi_area_m2)
	if v <= 0.0 or area <= 0.0:
		return 0.0
	var radius := sqrt(area / PI)
	var cross := (radius * 2.0) * KINETIC_SLAB_HEIGHT_M
	var watts := 0.5 * AIR_DENSITY_KG_M3 * cross * pow(v, 3.0)
	return watts / 1000.0


## Compact node subtitle: "8.2 m/s · 22°C · 48%"
static func pbi_display_string(wind_ms: float, temp_c: float, humidity_pct: float) -> String:
	return "%.0f m/s · %.0f°C · %.0f%%" % [wind_ms, temp_c, humidity_pct]


## Visual weather class for the cloud icon (0–4).
## 0 clear, 1 partly, 2 cloudy, 3 overcast, 4 raining.
static func weather_visual_class(cloud_frac: float, rain_mmh: float) -> int:
	if rain_mmh > 0.05:
		return 4
	var c := clampf(cloud_frac, 0.0, 1.0)
	if c < 0.15:
		return 0
	if c < 0.40:
		return 1
	if c < 0.70:
		return 2
	return 3
