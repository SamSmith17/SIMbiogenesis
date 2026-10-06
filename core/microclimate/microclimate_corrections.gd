class_name MicroclimateCorrections
extends RefCounted

## The PHYSICS half of a site's data corrections, applied inside
## WeatherService's typed accessors so every consumer — turbines, PV, NPC
## weather comfort, the extreme-weather evaluators (a playa dust storm then
## triggers from the CORRECTED wind) — sees the same corrected number.
##
## Static state on purpose: WeatherService must not name the Microclimate
## autoload (a bare autoload identifier breaks every --script selftest that
## compiles weather_service.gd). The resolver pushes the list in; an empty list
## is the identity, which is the state under --script and on any site without a
## calibration.
##
## Only UNCONDITIONAL affine corrections live here. A conditional one ("2 °C
## colder on calm clear nights") would need the features this accessor is the
## source of; those stay visual-only, in MicroclimateProfile.apply_corrections.

## var name → Vector2(mult, add), composed in list order.
static var _physics: Dictionary = {}


static func set_physics(corrections: Array) -> void:
	_physics = {}
	for c in corrections:
		if not (c is Dictionary) or not bool(c.get("enabled", true)) or not bool(c.get("physics", false)):
			continue
		var when: Variant = c.get("when", [])
		if when is Array and not (when as Array).is_empty():
			continue
		var key := str(c.get("var", ""))
		var prev: Vector2 = _physics.get(key, Vector2(1.0, 0.0))
		var m := float(c.get("mult", 1.0))
		var a := float(c.get("add", 0.0))
		if not (is_finite(m) and is_finite(a)):
			continue
		# (v·m0 + a0)·m + a
		_physics[key] = Vector2(prev.x * m, prev.y * m + a)


static func clear() -> void:
	_physics = {}


static func is_identity() -> bool:
	return _physics.is_empty()


## Apply to one value. NAN stays NAN (missing data is not "zero wind").
static func apply(var_name: String, v: float) -> float:
	if _physics.is_empty() or not is_finite(v) or not _physics.has(var_name):
		return v
	var ma: Vector2 = _physics[var_name]
	return v * ma.x + ma.y
