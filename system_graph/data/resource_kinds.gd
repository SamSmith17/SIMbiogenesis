class_name ResourceKinds
extends RefCounted

## Registry of trackable physical resource kinds for the graph editor.
## Each kind maps to display metadata, wire/port color, and default unit.
## User extensions load from user://resource_kinds.cfg (never committed).

const CONFIG_PATH := "user://resource_kinds.cfg"

const BUILTIN: Dictionary = {
	"electric": {
		"display": "Electric",
		"color": Color(0.941, 0.820, 0.282, 1.0),
		"unit": "kWh",
		"abbrev": "⚡",
	},
	"water": {
		"display": "Water",
		"color": Color(0.231, 0.510, 0.965, 1.0),
		"unit": "L",
		"abbrev": "💧",
	},
	"biomass": {
		"display": "Biomass",
		"color": Color(0.545, 0.353, 0.176, 1.0),
		"unit": "kg",
		"abbrev": "🌿",
	},
	"plastic_waste": {
		"display": "Waste Plastic",
		"color": Color(0.580, 0.639, 0.722, 1.0),
		"unit": "kg",
		"abbrev": "♻",
	},
	"plastic_shred": {
		"display": "Shredded Plastic",
		"color": Color(0.392, 0.710, 0.965, 1.0),
		"unit": "kg",
		"abbrev": "✂",
	},
	"biochar": {
		"display": "Biochar",
		"color": Color(0.180, 0.180, 0.180, 1.0),
		"unit": "kg",
		"abbrev": "🔥",
	},
	"hot_water": {
		"display": "Hot Water",
		"color": Color(0.937, 0.420, 0.420, 1.0),
		"unit": "L",
		"abbrev": "♨",
	},
	"woodgas": {
		"display": "Woodgas",
		"color": Color(0.706, 0.627, 0.353, 1.0),
		"unit": "m³",
		"abbrev": "💨",
	},
	"food": {
		"display": "Food",
		"color": Color(0.063, 0.722, 0.506, 1.0),
		"unit": "kg",
		"abbrev": "🍎",
	},
	"propane": {
		"display": "Propane",
		"color": Color(0.961, 0.620, 0.043, 1.0),
		"unit": "kg",
		"abbrev": "🛢",
	},
	"thermal": {
		"display": "Thermal",
		"color": Color(0.847, 0.329, 0.329, 1.0),
		"unit": "kWh",
		"abbrev": "♨",
	},
}

static var _extra: Dictionary = {}
static var _loaded: bool = false


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	_extra.clear()
	if not FileAccess.file_exists(CONFIG_PATH):
		return
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		return
	for section in cfg.get_sections():
		if section == "meta":
			continue
		var display: String = str(cfg.get_value(section, "display", section.capitalize()))
		var unit: String = str(cfg.get_value(section, "unit", "unit"))
		var abbrev: String = str(cfg.get_value(section, "abbrev", "•"))
		var cr: float = float(cfg.get_value(section, "color_r", 0.58))
		var cg: float = float(cfg.get_value(section, "color_g", 0.64))
		var cb: float = float(cfg.get_value(section, "color_b", 0.72))
		_extra[section] = {
			"display": display,
			"color": Color(cr, cg, cb, 1.0),
			"unit": unit,
			"abbrev": abbrev,
		}


static func all_kinds() -> Array:
	_ensure_loaded()
	var keys: Array = BUILTIN.keys()
	for k: String in _extra.keys():
		if not keys.has(k):
			keys.append(k)
	keys.sort()
	return keys


static func has_kind(kind_id: String) -> bool:
	_ensure_loaded()
	return BUILTIN.has(kind_id) or _extra.has(kind_id)


static func kind_meta(kind_id: String) -> Dictionary:
	_ensure_loaded()
	if BUILTIN.has(kind_id):
		return (BUILTIN[kind_id] as Dictionary).duplicate(true)
	if _extra.has(kind_id):
		return (_extra[kind_id] as Dictionary).duplicate(true)
	return {
		"display": kind_id.capitalize(),
		"color": Color(0.580, 0.639, 0.722, 1.0),
		"unit": "unit",
		"abbrev": "•",
	}


static func wire_color(kind_id: String) -> Color:
	if kind_id.is_empty():
		return Color(0.580, 0.639, 0.722, 1.0)
	return kind_meta(kind_id).get("color", Color(0.580, 0.639, 0.722, 1.0)) as Color


static func display_name(kind_id: String) -> String:
	return str(kind_meta(kind_id).get("display", kind_id))


static func default_unit(kind_id: String) -> String:
	return str(kind_meta(kind_id).get("unit", "unit"))


## Parse legacy free-text capacity strings like "50 gal" or "100 lb".
static func parse_capacity_text(text: String) -> Dictionary:
	var t := text.strip_edges()
	if t.is_empty():
		return {"qty": 100.0, "unit": "L"}
	var parts := t.split(" ", false)
	if parts.size() >= 2:
		var qty := float(parts[0])
		var unit := parts[1]
		return {"qty": qty, "unit": unit}
	return {"qty": 100.0, "unit": t}


## Infer resource kind from a container preset name.
static func infer_kind_from_name(name: String) -> String:
	var n := name.to_lower()
	if "water" in n or "tank" in n and "propane" not in n:
		return "water"
	if "propane" in n:
		return "propane"
	if "thermal" in n or "heat" in n:
		return "thermal"
	if "ev" in n or "battery" in n:
		return "electric"
	if "plastic" in n and "shred" in n:
		return "plastic_shred"
	if "plastic" in n:
		return "plastic_waste"
	if "biochar" in n:
		return "biochar"
	if "biomass" in n:
		return "biomass"
	if "food" in n:
		return "food"
	return "water"


## Parse legacy output_rate like "50 L/h" into a structured output entry.
static func parse_rate_text(rate_text: String) -> Dictionary:
	var t := rate_text.strip_edges()
	if t.is_empty():
		return {"kind": "water", "rate": 0.0, "unit": "L/h"}
	var parts := t.split(" ", false)
	var qty := 0.0
	var unit := "L/h"
	if parts.size() >= 1:
		qty = float(parts[0]) if parts[0].is_valid_float() else 0.0
	if parts.size() >= 2:
		unit = parts[1]
		if not unit.ends_with("/h"):
			unit = unit + "/h"
	var kind := "water"
	var ul := unit.to_lower()
	if "btu" in ul:
		kind = "thermal"
	elif "gal" in ul:
		kind = "water"
	elif "mi" in ul:
		kind = "electric"
	return {"kind": kind, "rate": qty, "unit": unit}


## Ensure processor specs carry structured inputs[] / outputs[].
func migrate_processor_specs(specs: Dictionary) -> void:
	if not specs.has("energy_source"):
		specs["energy_source"] = "ac" if float(specs.get("watts", 0.0)) > 0.0 else ""
	if specs.has("inputs") and specs.has("outputs"):
		return
	var outputs: Array = []
	if specs.has("output_rate"):
		outputs.append(parse_rate_text(str(specs.get("output_rate", ""))))
	else:
		outputs.append({"kind": "water", "rate": 0.0, "unit": "L/h"})
	specs["inputs"] = []
	specs["outputs"] = outputs
	if not specs.has("efficiency"):
		specs["efficiency"] = 1.0
	if not specs.has("energy_wh_per_unit"):
		var watts: float = float(specs.get("watts", 0.0))
		var rate: float = float(outputs[0].get("rate", 0.0)) if outputs.size() > 0 else 0.0
		specs["energy_wh_per_unit"] = (watts / rate) if rate > 0.0 else 0.0


## Ensure resource tank specs carry resource_kind + numeric capacity.
func migrate_resource_specs(specs: Dictionary) -> void:
	if not specs.has("resource_kind"):
		specs["resource_kind"] = infer_kind_from_name(str(specs.get("name", "")))
	if not specs.has("capacity_qty"):
		var parsed := parse_capacity_text(str(specs.get("capacity", "")))
		specs["capacity_qty"] = float(parsed.get("qty", 100.0))
		specs["capacity_unit"] = str(parsed.get("unit", default_unit(str(specs.get("resource_kind", "water")))))
	if not specs.has("level"):
		specs["level"] = 0.5
	if not specs.has("inflow_rate"):
		specs["inflow_rate"] = 0.0
	if not specs.has("outflow_rate"):
		specs["outflow_rate"] = 0.0
