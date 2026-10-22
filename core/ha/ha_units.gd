class_name HaUnits
extends RefCounted
## Home Assistant reading → the unit a sim value is kept in (pure).
##
## A sensor carries its unit in `unit_of_measurement` ("W", "kWh", "°F",
## "mph", "in/h", "%", "gal"…). convert() takes the raw state string and that
## unit and returns the value in the TARGET's unit, or a warning when the two
## are not the same kind of quantity (a link from a temperature sensor to a
## battery state of charge is never applied silently). A sensor with no unit
## is taken as already being in the target's unit.

## Per family: unit → factor to the family's base unit (base = factor 1).
const FAMILIES := {
	"power": {"W": 1.0, "kW": 1000.0, "MW": 1.0e6, "mW": 0.001},
	"energy": {"Wh": 1.0, "kWh": 1000.0, "MWh": 1.0e6},
	"voltage": {"V": 1.0, "mV": 0.001, "kV": 1000.0},
	"current": {"A": 1.0, "mA": 0.001},
	"speed": {"m/s": 1.0, "km/h": 1.0 / 3.6, "mph": 0.44704, "kn": 0.514444, "ft/s": 0.3048},
	"rain_rate": {"mm/h": 1.0, "in/h": 25.4, "cm/h": 10.0},
	"length": {"m": 1.0, "cm": 0.01, "mm": 0.001, "in": 0.0254, "ft": 0.3048, "km": 1000.0},
	"volume": {"L": 1.0, "mL": 0.001, "m³": 1000.0, "gal": 3.785411784, "ft³": 28.316846592},
	"irradiance": {"W/m²": 1.0},
	"illuminance": {"lx": 1.0},
	"frequency": {"Hz": 1.0},
	"flow": {"L/min": 1.0, "L/h": 1.0 / 60.0, "gal/min": 3.785411784, "m³/h": 1000.0 / 60.0},
}

## Spellings HA integrations use for the same unit.
const ALIASES := {
	"w": "W", "kw": "kW", "mw": "MW",
	"wh": "Wh", "kwh": "kWh", "mwh": "MWh",
	"v": "V", "mv": "mV", "kv": "kV", "a": "A", "ma": "mA",
	"m/s": "m/s", "km/h": "km/h", "kph": "km/h", "mph": "mph", "kn": "kn", "kt": "kn", "knots": "kn", "ft/s": "ft/s",
	"mm/h": "mm/h", "mm/hr": "mm/h", "in/h": "in/h", "in/hr": "in/h", "cm/h": "cm/h",
	"m": "m", "cm": "cm", "mm": "mm", "in": "in", "ft": "ft", "km": "km",
	"l": "L", "ml": "mL", "m³": "m³", "m3": "m³", "gal": "gal", "ft³": "ft³", "ft3": "ft³",
	"w/m²": "W/m²", "w/m2": "W/m²", "lx": "lx", "lux": "lx", "hz": "Hz",
	"l/min": "L/min", "l/h": "L/h", "gal/min": "gal/min", "gpm": "gal/min", "m³/h": "m³/h",
	"°c": "°C", "c": "°C", "℃": "°C", "°f": "°F", "f": "°F", "℉": "°F", "k": "K",
	"%": "%",
}

const TRUE_STATES := ["on", "true", "1", "yes", "open", "home", "raining", "rain", "detected", "wet"]
const FALSE_STATES := ["off", "false", "0", "no", "closed", "not_home", "dry", "clear"]
## States that carry no reading.
const NO_VALUE := ["unavailable", "unknown", "", "none", "null"]


static func canonical(unit: String) -> String:
	var u := unit.strip_edges()
	var k := u.to_lower()
	if ALIASES.has(k):
		return str(ALIASES[k])
	return u


static func family_of(unit: String) -> String:
	var u := canonical(unit)
	if u in ["°C", "°F", "K"]:
		return "temperature"
	if u == "%":
		return "percent"
	if u == "bool":
		return "bool"
	if u == "frac":
		return "percent"
	for f in FAMILIES.keys():
		if (FAMILIES[f] as Dictionary).has(u):
			return f
	return ""


## {ok, value: float, warn: String}. `raw` = HA state string. `target_unit`
## may be "bool" (→ 1.0 / 0.0) or "frac" (a 0..1 fraction).
static func convert(raw: String, from_unit: String, target_unit: String) -> Dictionary:
	var s := raw.strip_edges()
	var low := s.to_lower()
	if low in NO_VALUE:
		return {"ok": false, "value": 0.0, "warn": "no reading (%s)" % (s if not s.is_empty() else "empty")}
	if target_unit == "bool":
		if low in TRUE_STATES:
			return {"ok": true, "value": 1.0, "warn": ""}
		if low in FALSE_STATES:
			return {"ok": true, "value": 0.0, "warn": ""}
		if s.is_valid_float():
			return {"ok": true, "value": 1.0 if s.to_float() > 0.0 else 0.0, "warn": ""}
		return {"ok": false, "value": 0.0, "warn": "\"%s\" is neither on nor off" % s}
	var v: float
	if s.is_valid_float():
		v = s.to_float()
	elif low in TRUE_STATES:
		v = 1.0
	elif low in FALSE_STATES:
		v = 0.0
	else:
		return {"ok": false, "value": 0.0, "warn": "\"%s\" is not a number" % s}
	var fu := canonical(from_unit)
	var tu := canonical(target_unit) if target_unit != "frac" else "frac"
	if fu.is_empty() or fu == tu:
		return {"ok": true, "value": v, "warn": ""}
	var ff := family_of(fu)
	var tf := family_of(tu)
	if ff.is_empty():
		# An integration's own unit we do not know: use the number as it is,
		# and say so once on the link.
		return {"ok": true, "value": v, "warn": "unknown unit \"%s\" — used as %s" % [fu, tu]}
	if ff != tf:
		return {"ok": false, "value": 0.0, "warn": "a %s sensor (%s) cannot drive a value in %s" % [ff, fu, tu]}
	match ff:
		"temperature":
			return {"ok": true, "value": _from_c(_to_c(v, fu), tu), "warn": ""}
		"percent":
			# "%" → "frac" and back.
			if fu == "%" and tu == "frac":
				return {"ok": true, "value": v / 100.0, "warn": ""}
			if fu == "frac" and tu == "%":
				return {"ok": true, "value": v * 100.0, "warn": ""}
			return {"ok": true, "value": v, "warn": ""}
	var fam: Dictionary = FAMILIES[ff]
	return {"ok": true, "value": v * float(fam[fu]) / float(fam[tu]), "warn": ""}


## Apply a link's manual scale / offset / invert after the unit conversion.
static func adjust(v: float, scale: float = 1.0, offset: float = 0.0, invert: bool = false) -> float:
	var out := v * scale + offset
	return -out if invert else out


## 0..1 how well a sensor fits a target (for "compatible only" + ranking).
## Unit family first, then HA's device_class, then the domain.
static func compatibility(target_unit: String, target_kind: String, row: Dictionary) -> float:
	var domain := str(row.get("domain", ""))
	var unit := str(row.get("unit", ""))
	var dc := str(row.get("device_class", ""))
	if target_kind == "binary" or target_unit == "bool":
		if domain in ["switch", "binary_sensor", "input_boolean", "light", "fan", "climate"]:
			return 1.0
		if domain == "sensor" and unit.is_empty():
			return 0.3
		return 0.0
	if domain in ["switch", "light", "input_boolean", "automation", "script", "scene", "button", "update"]:
		return 0.0
	var tf := family_of(target_unit)
	var ff := family_of(unit)
	if not ff.is_empty() and ff == tf:
		return 1.0
	if not ff.is_empty() and not tf.is_empty() and ff != tf:
		return 0.0
	var want_dc := {"power": ["power"], "energy": ["energy"], "voltage": ["voltage"],
		"current": ["current"], "temperature": ["temperature"], "percent": ["battery", "humidity", "moisture"],
		"speed": ["wind_speed", "speed"], "rain_rate": ["precipitation_intensity"],
		"irradiance": ["irradiance"], "illuminance": ["illuminance"], "volume": ["volume", "water"],
		"length": ["distance", "precipitation"]}
	if (want_dc.get(tf, []) as Array).has(dc):
		return 0.9
	if domain in ["sensor", "number", "input_number"] and unit.is_empty():
		return 0.25
	return 0.1 if domain in ["sensor", "number", "input_number"] else 0.0


static func _to_c(v: float, u: String) -> float:
	match u:
		"°F":
			return (v - 32.0) * 5.0 / 9.0
		"K":
			return v - 273.15
	return v


static func _from_c(c: float, u: String) -> float:
	match u:
		"°F":
			return c * 9.0 / 5.0 + 32.0
		"K":
			return c + 273.15
	return c
