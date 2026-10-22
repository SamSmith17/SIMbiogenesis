class_name TimelineWeatherChannels
extends RefCounted
## Weather as timeline tracks (pure: the weather reader is passed in).
##
## Each channel is one WeatherService accessor (the same numbers the sky, the
## solar physics and the weather card use), sampled across the visible window.
## A track's source is "weather" and its channel one of the ids below. Values
## are kept in SI and converted for display only (the weather card's °F / °C
## switch, ui_prefs.cfg [units] imperial).
##
## WeatherService answers by calendar position for its loaded year, so a window
## that crosses into another year reads that year's dates from the same
## dataset. NAN (no data loaded, a variable the dataset lacks) leaves a gap.

const SOURCE := "weather"

## mode "avg" = mean of the samples in a bin, "peak" = their max (rain, gusts:
## a short burst must not average away). floor_zero = the axis starts at 0;
## fixed = [min, max] in SI.
const CHANNELS := [
	{"id": "wx_temp_c", "label": "Temperature", "accessor": "temperature_c", "si": "°C",
		"mode": "avg", "color": Color(0.98, 0.55, 0.35)},
	{"id": "wx_dewpoint_c", "label": "Dew point", "accessor": "dew_point_c", "si": "°C",
		"mode": "avg", "color": Color(0.55, 0.75, 0.98)},
	{"id": "wx_humidity_pct", "label": "Humidity", "accessor": "humidity_pct", "si": "%",
		"mode": "avg", "color": Color(0.45, 0.80, 0.95), "fixed": [0.0, 100.0]},
	{"id": "wx_wind_ms", "label": "Wind speed", "accessor": "wind_speed_ms", "si": "m/s",
		"mode": "avg", "color": Color(0.70, 0.88, 0.70), "floor_zero": true},
	{"id": "wx_gust_ms", "label": "Wind gusts", "accessor": "wind_gust_ms", "si": "m/s",
		"mode": "peak", "color": Color(0.55, 0.78, 0.55), "floor_zero": true},
	{"id": "wx_ghi_wm2", "label": "Solar radiation", "accessor": "solar_radiation_wm2", "si": "W/m²",
		"mode": "avg", "color": Color(1.00, 0.82, 0.31), "floor_zero": true},
	{"id": "wx_cloud_pct", "label": "Cloud cover", "accessor": "cloud_cover_frac", "si": "%",
		"mode": "avg", "color": Color(0.72, 0.76, 0.84), "fixed": [0.0, 100.0], "scale": 100.0},
	{"id": "wx_rain_mmh", "label": "Rain", "accessor": "rain_rate_mmh", "si": "mm/h",
		"mode": "peak", "color": Color(0.35, 0.60, 1.00), "floor_zero": true},
	{"id": "wx_snow_m", "label": "Snow depth", "accessor": "snow_depth_m", "si": "m",
		"mode": "avg", "color": Color(0.90, 0.95, 1.00), "floor_zero": true},
]

## Samples taken inside each bin (more = rain bursts are not missed).
const SUBSAMPLES := 3
## Above this many hours per bin, sample hourly-ish at most this many times.
const MAX_SUBSAMPLES := 6


static func find(id: String) -> Dictionary:
	for c in CHANNELS:
		if str(c["id"]) == id:
			return c
	return {}


static func is_weather(id: String) -> bool:
	return not find(id).is_empty()


## `n` bins over [t0, t1) absolute hours (the clock's epoch). `reader` is
## Callable(accessor: String, month: int, day: int, hour: float) -> float, in SI
## (cloud cover arrives as a fraction and is scaled by the channel's "scale").
static func bins(id: String, t0: float, t1: float, n: int, reader: Callable) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(maxi(n, 0))
	out.fill(NAN)
	var ch := find(id)
	if ch.is_empty() or n <= 0 or t1 <= t0 or not reader.is_valid():
		return out
	var w := (t1 - t0) / float(n)
	var subs := clampi(int(ceil(w)), SUBSAMPLES, MAX_SUBSAMPLES) if w > 1.0 else 1
	var peak := str(ch.get("mode", "avg")) == "peak"
	var acc := str(ch["accessor"])
	var scale := float(ch.get("scale", 1.0))
	for b in n:
		var sum := 0.0
		var mx := -INF
		var cnt := 0
		for k in subs:
			var t := t0 + w * (float(b) + (float(k) + 0.5) / float(subs))
			var d := abs_to_date(t)
			var v := float(reader.call(acc, int(d["month"]), int(d["day"]), float(d["hour"])))
			if is_nan(v) or is_inf(v):
				continue
			v *= scale
			sum += v
			mx = maxf(mx, v)
			cnt += 1
		if cnt > 0:
			out[b] = mx if peak else sum / float(cnt)
	return out


## Zoom-stable bins (TimelineBinning.from_function): WeatherService's series
## are hourly and linear in between, so each anchored bin reads its edges and
## every whole hour inside it — exact min / max / mean of what the weather
## data holds, whatever the zoom. `reader` as for bins().
static func bins_exact(id: String, w: float, i0: int, n: int, reader: Callable) -> Dictionary:
	var ch := find(id)
	if ch.is_empty() or not reader.is_valid():
		return TimelineBinning.empty(w, i0, n)
	var acc := str(ch["accessor"])
	var scale := float(ch.get("scale", 1.0))
	var f := func(t: float) -> float:
		var d := abs_to_date(t)
		var v := float(reader.call(acc, int(d["month"]), int(d["day"]), float(d["hour"])))
		return v * scale if not is_nan(v) else NAN
	return TimelineBinning.from_function(f, 1.0, w, i0, n)


## {year, month, day, hour} for absolute hours (proleptic Gregorian, hour 0 =
## 0001-01-01 00:00 — CelestialClock's and TimeDirector's epoch).
static func abs_to_date(h: float) -> Dictionary:
	var days := int(floor(h / 24.0))
	var hour := h - float(days) * 24.0
	var y := int(float(days) / 365.2425) + 1
	while _days_before_year(y) > days:
		y -= 1
	while _days_before_year(y + 1) <= days:
		y += 1
	var doy := days - _days_before_year(y)   # 0-based
	var dim := [31, 29 if _leap(y) else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
	var m := 0
	while m < 11 and doy >= int(dim[m]):
		doy -= int(dim[m])
		m += 1
	return {"year": y, "month": m + 1, "day": doy + 1, "hour": hour}


## Display conversion: {value, unit}. Imperial: °F, mph, in/h, in, (% and
## W/m² unchanged).
static func display(si_value: float, si_unit: String, imperial: bool) -> Dictionary:
	if not imperial or is_nan(si_value):
		return {"value": si_value, "unit": si_unit}
	match si_unit:
		"°C":
			return {"value": si_value * 9.0 / 5.0 + 32.0, "unit": "°F"}
		"m/s":
			return {"value": si_value / 0.44704, "unit": "mph"}
		"mm/h":
			return {"value": si_value / 25.4, "unit": "in/h"}
		"m":
			return {"value": si_value / 0.0254, "unit": "in"}
	return {"value": si_value, "unit": si_unit}


## The axis range in SI for a window of bins: fixed channels keep theirs,
## floor_zero ones start at 0, the rest get their min / max with a margin.
## [NAN, NAN] when the window holds no value.
static func axis_range(id: String, samples: PackedFloat32Array) -> Vector2:
	var ch := find(id)
	var fixed: Variant = ch.get("fixed", null)
	var lo := INF
	var hi := -INF
	for v in samples:
		if not is_nan(v):
			lo = minf(lo, v)
			hi = maxf(hi, v)
	if lo == INF:
		return Vector2(NAN, NAN)
	if fixed is Array:
		return Vector2(float(fixed[0]), float(fixed[1]))
	if bool(ch.get("floor_zero", false)):
		return Vector2(0.0, maxf(hi * 1.15, 0.5))
	var pad := maxf((hi - lo) * 0.1, 0.5)
	return Vector2(lo - pad, hi + pad)


static func _days_before_year(y: int) -> int:
	var yy := y - 1
	return 365 * yy + yy / 4 - yy / 100 + yy / 400


static func _leap(y: int) -> bool:
	return (y % 4 == 0 and y % 100 != 0) or y % 400 == 0
