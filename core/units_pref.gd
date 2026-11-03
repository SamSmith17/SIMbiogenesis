class_name UnitsPref
extends RefCounted

## The player's units for road things: miles and gallons, or kilometres and
## litres. ONE setting shared by the vehicle designer (trip, range, economy)
## and the ride dashboard (speed, distance, range, fuel). Stored in
## user://ui_prefs.cfg [units] metric; a taste, not a site property.
## Autoload-free so selftests can use it.

const PREFS_PATH := "user://ui_prefs.cfg"
const MI_M := 1609.344
const GAL_L := 3.78541

static var _loaded := false
static var _metric := false
## Bumped on every change, so a UI can poll it cheaply.
static var generation := 0


static func metric() -> bool:
	if not _loaded:
		_loaded = true
		var cf := ConfigFile.new()
		if cf.load(PREFS_PATH) == OK:
			_metric = bool(cf.get_value("units", "metric", false))
	return _metric


static func set_metric(on: bool) -> void:
	metric()
	if on == _metric:
		return
	_metric = on
	generation += 1
	var cf := ConfigFile.new()
	cf.load(PREFS_PATH)
	cf.set_value("units", "metric", on)
	cf.save(PREFS_PATH)


## "12 mi" / "19 km" from miles.
static func dist_mi(mi: float, decimals: int = 0) -> String:
	var fmt := "%." + str(decimals) + "f %s"
	return fmt % [mi * MI_M / 1000.0, "km"] if metric() else fmt % [mi, "mi"]


## "12 mi" / "19 km" from metres.
static func dist_m(m: float, decimals: int = 0) -> String:
	return dist_mi(m / MI_M, decimals)


## Speed from m/s: "34 mph" / "55 km/h".
static func speed(mps: float) -> String:
	return "%.0f km/h" % (mps * 3.6) if metric() else "%.0f mph" % (mps * 2.23694)


## A volume of fuel from litres: "13.2 gal" / "50 L".
static func fuel_l(litres: float, decimals: int = 1) -> String:
	var fmt := "%." + str(decimals) + "f %s"
	return fmt % [litres, "L"] if metric() else fmt % [litres / GAL_L, "gal"]


## Economy from miles per US gallon: "14.2 mpg" / "16.6 L/100 km".
static func economy_mpg(mpg: float) -> String:
	if mpg <= 0.0:
		return "—"
	return "%.1f L/100 km" % (235.215 / mpg) if metric() else "%.1f mpg" % mpg


## The unit word the trip's distance field takes, and back.
static func dist_unit() -> String:
	return "km" if metric() else "mi"


static func mi_to_shown(mi: float) -> float:
	return mi * MI_M / 1000.0 if metric() else mi


static func shown_to_mi(v: float) -> float:
	return v * 1000.0 / MI_M if metric() else v


## Fuel price per shown volume (per gallon / per litre), from $/gal.
static func price_to_shown(per_gal: float) -> float:
	return per_gal / GAL_L if metric() else per_gal


static func shown_to_price(v: float) -> float:
	return v * GAL_L if metric() else v


## Test hook: forget the cached value (selftests).
static func reset_for_test(on: bool = false) -> void:
	_loaded = true
	_metric = on
	generation += 1
