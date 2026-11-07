class_name EspWorldProbe
extends RefCounted

## What a sensor at one spot measures at one instant: the `source(src, at_h)`
## Callable EspSim reads. Everything is looked up at the asked instant (never
## "now"), so the twin stays a pure function of time and scrubs.
##
## Sources (source ids are the `src` of EspParts entities):
##   air.temp_c / air.rh_pct    WeatherService (the site's real weather)
##   air.pressure_hpa           WeatherService surface pressure (forecast
##                              window), else the standard atmosphere at the
##                              spot's height above sea level (an estimate)
##   air.co2_ppm / eco2 / tvoc  outdoor 420 ppm + people within 4 m
##                              (ESTIMATE: no room air model)
##   air.pm1 / pm25 / pm10      AirQualityService (CAMS), else clean air
##   light.lux / uv_index       measured GHI (WeatherService), else clear sky;
##                              lux = GHI × 115 lm/W, UVI ≈ GHI × 0.0085
##                              (ESTIMATES)
##   soil.moisture_pct          a rain-history bucket (ESTIMATE)
##   motion.present             people within the sensor's range
##   dist.m                     `distance_fn` (a ray in the world), else the
##                              bench distance
##   gps.*                      the site's position and height
##   probe.temp_c               air temperature unless bound to something hot
##   everything else (power, weight, flow, a float, a switch) comes from
##   `bindings`: {src: Callable(at_h) -> float | float}; unbound reads 0.
##
## Autoloads are found by path, never by name, so this compiles under
## --script (the headless selftest trap).

const LUX_PER_WM2 := 115.0
const UVI_PER_WM2 := 0.0085
const CO2_OUTDOOR := 420.0
const CO2_PER_PERSON := 35.0
const PM25_CLEAN := 6.0
const CACHE_MAX := 6000

var pos := Vector3.ZERO
var lat := 0.0
var lon := 0.0
var elev_m := 0.0
var boot_h := NAN
var bench_distance_m := 1.0
var bindings := {}
var people_fn := Callable()        # (pos: Vector3, radius_m: float, at_h: float) -> int
var distance_fn := Callable()      # (at_h: float) -> float metres
var rssi_dbm := -60.0
## The site's graph (SystemGraphView.model): bound sources (EspBindings) read it.
var graph_model: Object = null
## (gid, at_h) -> a tank's level at that instant, NAN = unknown: its
## ResourceTimeline, so a bound ultrasonic's history is the tank's.
var tank_level_fn := Callable()
var _clock := CelestialClock.new()
var _cache := {}
var _notes := {}


## A probe at a world position, filled from the running game.
static func for_main(main: Node, world_pos: Vector3) -> EspWorldProbe:
	var p := EspWorldProbe.new()
	p.pos = world_pos
	if main != null:
		p.lat = float(main.get("latitude"))
		p.lon = float(main.get("longitude"))
		var loader := main.get_node_or_null("Terrain/TerrainLoader")
		if loader == null:
			loader = main.find_child("TerrainLoader", true, false)
		if loader != null and loader.has_method("ground_height_at"):
			p.elev_m = float(loader.call("ground_height_at", world_pos.x, world_pos.z)) + float(loader.get("_built_center_elev"))
	p._clock.latitude = p.lat
	p._clock.longitude = p.lon
	return p


func setup(at_lat: float, at_lon: float, at_elev_m: float) -> EspWorldProbe:
	lat = at_lat
	lon = at_lon
	elev_m = at_elev_m
	_clock.latitude = lat
	_clock.longitude = lon
	_cache.clear()
	return self


func source() -> Callable:
	return value


## Why a source is an estimate (for the card), "" when it is measured.
func note_of(src: String) -> String:
	return str(_notes.get(src, ""))


static func _autoload(name: String) -> Node:
	var ml := Engine.get_main_loop()
	if ml is SceneTree:
		return (ml as SceneTree).root.get_node_or_null(name)
	return null


func value(src: String, t: float) -> float:
	# Bound sources are the graph's live values: never cached (a paused clock
	# keeps t still while the tank drains under the player's hand).
	if EspBindings.is_binding(src) or bindings.has(src):
		return _value(src, t)
	var key := "%s@%.6f" % [src, t]
	if _cache.has(key):
		return float(_cache[key])
	var v := _value(src, t)
	if _cache.size() > CACHE_MAX:
		_cache.clear()
	_cache[key] = v
	return v


func _value(src: String, t: float) -> float:
	if EspBindings.is_binding(src):
		var lv := NAN
		if src.begins_with("tank.") and tank_level_fn.is_valid():
			lv = float(tank_level_fn.call(EspBindings.item_of(src), t))
		return EspBindings.read(graph_model, src, lon, lv)
	if bindings.has(src):
		var b: Variant = bindings[src]
		if b is Callable:
			var r: Variant = (b as Callable).call(t)
			return float(r) if (r is float or r is int) else (1.0 if r is bool and r else (0.0 if r is bool else NAN))
		return float(b)
	var dd: Dictionary = _clock.abs_hours_to_date(t)
	var mo := int(dd.get("month", 1))
	var dy := int(dd.get("day", 1))
	var hr := float(dd.get("day_time", 12.0))
	var ws := _autoload("WeatherService")
	match src:
		"air.temp_c", "probe.temp_c":
			return _ws(ws, "temperature_c", mo, dy, hr, 15.0, src)
		"air.rh_pct":
			return _ws(ws, "humidity_pct", mo, dy, hr, 60.0, src)
		"air.pressure_hpa":
			var p := NAN
			if ws != null and ws.has_method("surface_pressure_hpa"):
				p = float(ws.call("surface_pressure_hpa", mo, dy, hr))
			if is_nan(p):
				_notes[src] = "standard atmosphere at %d m (no pressure in the weather data for this date)" % int(elev_m)
				return isa_pressure_hpa(elev_m)
			_notes.erase(src)
			return p
		"air.co2_ppm", "air.eco2_ppm":
			_notes[src] = "outdoor CO₂ plus people nearby (estimate)"
			return CO2_OUTDOOR + CO2_PER_PERSON * float(_people(4.0, t))
		"air.tvoc_ppb":
			_notes[src] = "estimate"
			return 60.0 + 25.0 * float(_people(4.0, t))
		"air.pm1_ugm3", "air.pm25_ugm3", "air.pm4_ugm3", "air.pm10_ugm3":
			var aq := _autoload("AirQualityService")
			var pm25 := NAN
			var pm10 := NAN
			if aq != null and aq.has_method("pm25_ugm3"):
				pm25 = float(aq.call("pm25_ugm3", t))
				pm10 = float(aq.call("pm10_ugm3", t))
			if is_nan(pm25):
				_notes[src] = "clean background air (no air-quality data for this date)"
				pm25 = PM25_CLEAN
			if is_nan(pm10):
				pm10 = pm25 * 1.6
			match src:
				"air.pm1_ugm3":
					return pm25 * 0.7
				"air.pm25_ugm3":
					return pm25
				"air.pm4_ugm3":
					return (pm25 + pm10) * 0.5
			return pm10
		"air.gas_ohm":
			# A metal-oxide plate's resistance falls as VOCs rise: clean air
			# ~200 kΩ, an occupied room lower (Bosch's own scale is relative).
			_notes[src] = "clean air, less with people nearby (estimate)"
			return 200000.0 / (1.0 + 0.35 * float(_people(4.0, t)))
		"air.voc_index":
			_notes[src] = "Sensirion's index: 100 = the room's usual air (estimate)"
			return 100.0 + 25.0 * float(_people(4.0, t))
		"air.nox_index":
			_notes[src] = "Sensirion's index: 1 = no NOx events (estimate)"
			return 1.0
		"air.wind_ms":
			_notes[src] = "the weather's 10 m wind (an anemometer lower down reads less)"
			return _ws(ws, "wind_speed_ms", mo, dy, hr, 2.0, "air.wind_ms_fallback")
		"rain.mmh":
			var r := NAN
			if ws != null and ws.has_method("rain_rate_mmh"):
				r = float(ws.call("rain_rate_mmh", mo, dy, hr))
			return 0.0 if is_nan(r) else maxf(0.0, r)
		"leak.wet":
			_notes[src] = "dry unless it is bound to a tank"
			return 0.0
		"accel.z":
			return 9.80665
		"input.encoder":
			return 0.0
		"adc.v":
			_notes[src] = "whatever you wire to A0 (the twin reads mid-scale)"
			return 1.65
		"presence.cm":
			return 150.0 if _people(6.0, t) > 0 else 0.0
		"light.lux":
			_notes[src] = "sunlight on an open sensor (estimate)"
			return ghi(t, mo, dy, hr, ws) * LUX_PER_WM2
		"light.uv_index":
			_notes[src] = "estimate from sunlight"
			return ghi(t, mo, dy, hr, ws) * UVI_PER_WM2
		"soil.moisture_pct":
			_notes[src] = "rain over the last day (estimate)"
			var rain := 0.0
			if ws != null and ws.has_method("rain_24h_mm"):
				rain = float(ws.call("rain_24h_mm", mo, dy, hr))
			return soil_moisture_pct(rain if not is_nan(rain) else 0.0)
		"motion.present":
			return 1.0 if _people(7.0, t) > 0 else 0.0
		"dist.m":
			if distance_fn.is_valid():
				return float(distance_fn.call(t))
			return bench_distance_m
		"gps.lat":
			return lat
		"gps.lon":
			return lon
		"gps.alt_m":
			return elev_m
		"gps.sats":
			return 9.0
		"diag.boot_h":
			return boot_h
		"diag.rssi":
			return rssi_dbm
	return 0.0


func _ws(ws: Node, fn: String, mo: int, dy: int, hr: float, fallback: float, src: String) -> float:
	if ws != null and ws.has_method(fn):
		var v := float(ws.call(fn, mo, dy, hr))
		if not is_nan(v):
			_notes.erase(src)
			return v
	_notes[src] = "no weather data: a typical value"
	return fallback


func _people(radius_m: float, t: float) -> int:
	if people_fn.is_valid():
		return int(people_fn.call(pos, radius_m, t))
	return 0


## Global horizontal sunlight, W/m²: the weather's measured value when there
## is one, else clear sky at the site.
func ghi(t: float, mo: int, dy: int, hr: float, ws: Node) -> float:
	if ws != null and ws.has_method("has_data") and bool(ws.call("has_data")) and ws.has_method("solar_radiation_wm2"):
		var g := float(ws.call("solar_radiation_wm2", mo, dy, hr))
		if not is_nan(g):
			return maxf(0.0, g)
	return maxf(0.0, SolarIrradiance.ghi_wm2(lat, lon, t))


## The ISA barometric formula, hPa at a height above sea level.
static func isa_pressure_hpa(h_m: float) -> float:
	return 1013.25 * pow(maxf(0.0, 1.0 - 2.25577e-5 * h_m), 5.25588)


## A bare soil's moisture from the last day's rain: dry soil ~20 %, wet ~70 %.
static func soil_moisture_pct(rain_24h_mm: float) -> float:
	return clampf(20.0 + 50.0 * (1.0 - exp(-rain_24h_mm / 12.0)), 0.0, 100.0)
