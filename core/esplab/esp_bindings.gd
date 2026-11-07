class_name EspBindings
extends RefCounted

## What a part on a placed board can measure on the site's graph, instead of
## the world at its spot: an ultrasonic sensor over a tank, a scale under it,
## a float in it, a current sensor on a load, a battery's voltage, a relay
## switching a load. A binding is a source id stored in the part instance's
## `measures` ({entity k: source}), read by EspWorldProbe through
## `read(model, src)`.
##
## Source ids:
##   tank.<gid>.distance_m   the gap from the lid to the water: the tank's
##                           height × (1 − level); height = specs.height_m,
##                           else the side of a cube of its volume (estimate)
##   tank.<gid>.high         1 when the tank is at least FLOAT_LEVEL full
##   tank.<gid>.mass_kg      the stock, kg (litres × the kind's density)
##   item.<gid>.voltage      a battery's voltage
##   load.<gid>.power_w / current_a / energy_wh / ac_v / ac_hz / pf
##                           a load's (or a panel's) power; current = power /
##                           its voltage (the item's, else NOMINAL_DC_V for a
##                           DC part, the site's mains for an AC one)
##   item.<gid>.switch       a load's / machine's on / off (relays follow it)
##
## Values are the graph's CURRENT ones (specs), so a bound reading is live,
## not a function of past time; the compare (Phase 6) reads tank timelines
## for history.

const FLOAT_LEVEL := 0.9
const NOMINAL_DC_V := 12.8

## Which binding families an entity's default source can take.
const FAMILIES := {
	"dist.m": [["tank", "distance_m", "Distance to the water in"]],
	"level.float": [["tank", "high", "Float in"]],
	"leak.wet": [["tank", "high", "Water reaching it in"]],
	"mass.kg": [["tank", "mass_kg", "Weight of"]],
	"elec.bus_v": [["battery", "voltage", "Voltage of"]],
	"elec.current_a": [["load", "current_a", "Current through"]],
	"elec.power_w": [["load", "power_w", "Power of"]],
	"elec.ac_v": [["load", "ac_v", "Mains voltage at"]],
	"elec.ac_a": [["load", "current_ac", "Current through"]],
	"elec.ac_w": [["load", "power_w", "Power of"]],
	"elec.ac_wh": [["load", "energy_wh", "Energy used by"]],
	"elec.ac_hz": [["load", "ac_hz", "Mains frequency at"]],
	"elec.ac_pf": [["load", "pf", "Power factor of"]],
	"actuator.switch": [["switchable", "switch", "Switches"]],
	"actuator.light": [["switchable", "switch", "Switches"]],
}


## [[source id, label]] for an entity's default source over the graph items.
static func choices(default_src: String, items: Array) -> Array:
	var out: Array = []
	var fams: Array = FAMILIES.get(default_src, [])
	for fam in fams:
		for it in items:
			if not (it is Dictionary) or str(it.get("id", "")).begins_with("virtual_"):
				continue
			if not _in_family(it, str(fam[0])):
				continue
			var prefix := "item" if str(fam[0]) in ["battery", "switchable"] else str(fam[0])
			out.append(["%s.%s.%s" % [prefix, it["id"], fam[1]], "%s %s" % [fam[2], _name(it)]])
	return out


static func is_binding(src: String) -> bool:
	return src.begins_with("tank.") or src.begins_with("item.") or src.begins_with("load.")


static func _in_family(it: Dictionary, fam: String) -> bool:
	var t := str(it.get("type", ""))
	match fam:
		"tank":
			return t == "resource"
		"battery":
			return t in ["battery", "smartbattery"]
		"load":
			return t in ["appliance", "acload", "panel"]
		"switchable":
			return t in ["appliance", "acload", "processor"]
	return false


static func _name(it: Dictionary) -> String:
	var s: Dictionary = it.get("specs", {})
	var n := str(s.get("name", ""))
	return n if n != "" else str(it.get("type", "item"))


## The graph item a binding names ("" when it is not one).
static func item_of(src: String) -> String:
	if not is_binding(src):
		return ""
	var parts := src.split(".")
	return parts[1] if parts.size() >= 3 else ""


## The site's mains: 120 V / 60 Hz in the Americas, else 230 V / 50 Hz.
static func mains(lon: float) -> Vector2:
	return Vector2(120.0, 60.0) if lon < -30.0 and lon > -170.0 else Vector2(230.0, 50.0)


## A binding's current value from a graph model (anything with get_item).
## NAN when the item is gone.
## `level` (when given) replaces the tank's current level: the probe passes a
## tank timeline's level at a past instant (the comparison's history).
static func read(model: Object, src: String, lon: float = 0.0, level_at: float = NAN) -> float:
	if model == null or not is_binding(src):
		return NAN
	var bits := src.split(".")
	if bits.size() < 3:
		return NAN
	var it: Dictionary = model.call("get_item", bits[1])
	if it.is_empty():
		return NAN
	var s: Dictionary = it.get("specs", {})
	var f := bits[2]
	var t := str(it.get("type", ""))
	match bits[0]:
		"tank":
			var level := clampf(float(s.get("level", 0.0)) if is_nan(level_at) else level_at, 0.0, 1.0)
			match f:
				"distance_m":
					return tank_height_m(s) * (1.0 - level)
				"high":
					return 1.0 if level >= FLOAT_LEVEL else 0.0
				"mass_kg":
					var stock := float(s.get("stock_l", level * float(s.get("capacity_qty", 0.0))))
					return stock * float(s.get("density_kg_l", 1.0))
		"item":
			match f:
				"voltage":
					return float(s.get("voltage", NOMINAL_DC_V))
				"switch":
					if it.has("is_on") and it["is_on"] != null and not bool(it["is_on"]):
						return 0.0
					var cs := str(s.get("current_state", s.get("requested_state", "on"))).to_lower()
					return 0.0 if cs == "off" else 1.0
		"load":
			var w := load_watts(it)
			var mv := mains(lon)
			var ac := t != "panel"
			match f:
				"power_w":
					return w
				"current_a":
					var v := float(s.get("voltage", NOMINAL_DC_V if not ac else mv.x))
					return w / maxf(v, 0.1)
				"current_ac":
					return w / mv.x
				"energy_wh":
					return float(s.get("energy_kwh", 0.0)) * 1000.0
				"ac_v":
					return mv.x
				"ac_hz":
					return mv.y
				"pf":
					return 1.0
	return NAN


## What a load draws now (W): 0 when it is off; a panel's output.
static func load_watts(it: Dictionary) -> float:
	var s: Dictionary = it.get("specs", {})
	if str(it.get("type", "")) == "panel":
		return float(s.get("current_output_kw", 0.0)) * 1000.0
	var cs := str(s.get("current_state", s.get("requested_state", "on"))).to_lower()
	if cs == "off" or (it.has("is_on") and it["is_on"] != null and not bool(it["is_on"])):
		return 0.0
	return float(s.get("avg_watts", 0.0))


## A tank's inside height (m): its own, else a cube of its volume.
static func tank_height_m(s: Dictionary) -> float:
	var h := float(s.get("height_m", 0.0))
	if h > 0.0:
		return h
	var litres := float(s.get("capacity_qty", s.get("capacity_l", 1000.0)))
	return pow(maxf(litres, 1.0) / 1000.0, 1.0 / 3.0)
