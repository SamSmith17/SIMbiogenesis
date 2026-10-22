class_name HaTargets
extends RefCounted
## Every simulation value a Home Assistant sensor can drive (pure).
##
## A TARGET is one value: the site's battery state of charge, the measured
## outdoor temperature, one graph node's live power, a tank's level. Its id is
## stable and readable:
##   site.<field>              the SolarUI energy picture
##   weather.<field>           the weather station readings
##   item.<graph id>.<field>   a graph node (the field ids are the old
##                             specs.ha_links roles, so links migrate 1:1)
## A target is {id, label, group, unit, kind ("numeric" | "binary"), scope
## ("site" | "item"), item_id, field, item_type}.

const SITE_FIELDS := [
	{"field": "battery_soc", "label": "Battery state of charge", "unit": "%", "kind": "numeric"},
	{"field": "solar_kw", "label": "Solar production", "unit": "kW", "kind": "numeric"},
	{"field": "load_kw", "label": "Power use (load)", "unit": "kW", "kind": "numeric"},
	{"field": "daily_solar_kwh", "label": "Solar produced today", "unit": "kWh", "kind": "numeric"},
]
const WEATHER_FIELDS := [
	{"field": "temp_c", "label": "Outdoor temperature", "unit": "°C", "kind": "numeric"},
	{"field": "wind_ms", "label": "Wind speed", "unit": "m/s", "kind": "numeric"},
	{"field": "irradiance", "label": "Solar radiation", "unit": "W/m²", "kind": "numeric"},
	{"field": "lux", "label": "Light level", "unit": "lx", "kind": "numeric"},
	{"field": "rain_rate", "label": "Rain rate", "unit": "mm/h", "kind": "numeric"},
	{"field": "raining", "label": "Raining", "unit": "bool", "kind": "binary"},
]

## Graph node fields by item type. Field ids for the first six types are the
## roles the old inspector stored in specs.ha_links.
const _LOAD := [
	{"field": "power", "label": "Power", "unit": "W", "kind": "numeric"},
	{"field": "energy", "label": "Energy used", "unit": "kWh", "kind": "numeric"},
	{"field": "voltage", "label": "Voltage", "unit": "V", "kind": "numeric"},
	{"field": "current", "label": "Current", "unit": "A", "kind": "numeric"},
	{"field": "switch", "label": "On / off", "unit": "bool", "kind": "binary"},
]
const _BATTERY := [
	{"field": "soc", "label": "State of charge", "unit": "%", "kind": "numeric"},
	{"field": "voltage", "label": "Voltage", "unit": "V", "kind": "numeric"},
	{"field": "power", "label": "Power (+ charging)", "unit": "W", "kind": "numeric"},
	{"field": "current", "label": "Current", "unit": "A", "kind": "numeric"},
]
const ITEM_FIELDS := {
	"appliance": _LOAD,
	"acload": _LOAD,
	"panel": [
		{"field": "power", "label": "PV power", "unit": "W", "kind": "numeric"},
		{"field": "voltage", "label": "String voltage", "unit": "V", "kind": "numeric"},
		{"field": "current", "label": "String current", "unit": "A", "kind": "numeric"},
	],
	"battery": _BATTERY,
	"smartbattery": _BATTERY,
	"controller": [
		{"field": "ac_power", "label": "AC output", "unit": "W", "kind": "numeric"},
		{"field": "voltage", "label": "AC voltage", "unit": "V", "kind": "numeric"},
		{"field": "current", "label": "AC current", "unit": "A", "kind": "numeric"},
	],
	"wind": [{"field": "power", "label": "Power", "unit": "W", "kind": "numeric"}],
	"hydro": [{"field": "power", "label": "Power", "unit": "W", "kind": "numeric"}],
	"resource": [
		{"field": "level_pct", "label": "Level", "unit": "%", "kind": "numeric"},
		{"field": "stock_l", "label": "Amount stored", "unit": "L", "kind": "numeric"},
	],
	"processor": [{"field": "switch", "label": "Running", "unit": "bool", "kind": "binary"}],
	"shelly4pm": [
		{"field": "c0_power", "label": "Channel 1 power", "unit": "W", "kind": "numeric"},
		{"field": "c0_switch", "label": "Channel 1 on / off", "unit": "bool", "kind": "binary"},
		{"field": "c0_energy", "label": "Channel 1 energy", "unit": "kWh", "kind": "numeric"},
		{"field": "c1_power", "label": "Channel 2 power", "unit": "W", "kind": "numeric"},
		{"field": "c1_switch", "label": "Channel 2 on / off", "unit": "bool", "kind": "binary"},
		{"field": "c1_energy", "label": "Channel 2 energy", "unit": "kWh", "kind": "numeric"},
		{"field": "c2_power", "label": "Channel 3 power", "unit": "W", "kind": "numeric"},
		{"field": "c2_switch", "label": "Channel 3 on / off", "unit": "bool", "kind": "binary"},
		{"field": "c2_energy", "label": "Channel 3 energy", "unit": "kWh", "kind": "numeric"},
		{"field": "c3_power", "label": "Channel 4 power", "unit": "W", "kind": "numeric"},
		{"field": "c3_switch", "label": "Channel 4 on / off", "unit": "bool", "kind": "binary"},
		{"field": "c3_energy", "label": "Channel 4 energy", "unit": "kWh", "kind": "numeric"},
	],
}

const TYPE_GROUPS := {
	"appliance": "Loads", "acload": "Loads", "panel": "Solar", "battery": "Batteries",
	"smartbattery": "Batteries", "controller": "Inverters & controllers", "wind": "Wind & hydro",
	"hydro": "Wind & hydro", "resource": "Tanks & ponds", "processor": "Machines", "shelly4pm": "Smart plugs & relays",
}

## Old SolarUI click-to-link field → target id (the HUD labels open the picker
## on these, and the legacy solar_ui_ha_entities.cfg migrates through it).
const SOLAR_UI_KEYS := {
	"battery_soc": "site.battery_soc", "solar": "site.solar_kw", "load": "site.load_kw",
	"daily_solar": "site.daily_solar_kwh", "solar_radiation": "weather.irradiance",
	"lux": "weather.lux", "rain_rate": "weather.rain_rate", "rain_state": "weather.raining",
	"temperature": "weather.temp_c", "wind_speed": "weather.wind_ms",
}


static func site_targets() -> Array:
	var out: Array = []
	for f in SITE_FIELDS:
		out.append(_mk("site.%s" % f["field"], f, "Energy (whole site)", "site", "", ""))
	for f in WEATHER_FIELDS:
		out.append(_mk("weather.%s" % f["field"], f, "Weather station", "site", "", ""))
	return out


static func fields_for_type(itype: String) -> Array:
	return (ITEM_FIELDS.get(itype, []) as Array).duplicate(true)


## Every target in the given graph items (+ the site ones), in display order.
## Items with no linkable fields, virtual mirrors and compounds are skipped.
static func all_targets(items: Array) -> Array:
	var out := site_targets()
	var rows: Array = []
	for it in items:
		if not (it is Dictionary):
			continue
		var itype := str(it.get("type", ""))
		if not ITEM_FIELDS.has(itype) or str(it.get("id", "")).begins_with("virtual_"):
			continue
		var iid := str(it.get("id", ""))
		var name := item_label(it)
		for f in ITEM_FIELDS[itype]:
			var t := _mk("item.%s.%s" % [iid, f["field"]], f, str(TYPE_GROUPS.get(itype, "Other")), "item", iid, itype)
			t["item_label"] = name
			t["label"] = "%s — %s" % [name, f["label"]]
			rows.append(t)
	rows.sort_custom(func(a, b):
		if str(a["group"]) != str(b["group"]):
			return str(a["group"]) < str(b["group"])
		return str(a["label"]) < str(b["label"]))
	out.append_array(rows)
	return out


## {scope, item_id, field} for a target id ({} if malformed).
static func parse(target_id: String) -> Dictionary:
	var parts := target_id.split(".")
	if parts.size() == 2 and parts[0] in ["site", "weather"]:
		return {"scope": parts[0], "item_id": "", "field": parts[1]}
	if parts.size() >= 3 and parts[0] == "item":
		# Graph ids never contain dots, but be safe: the field is the last part.
		var field := parts[parts.size() - 1]
		var iid := ".".join(parts.slice(1, parts.size() - 1))
		return {"scope": "item", "item_id": iid, "field": field}
	return {}


static func item_target_id(item_id: String, field: String) -> String:
	return "item.%s.%s" % [item_id, field]


## The target dict for an id, given the items (or {} if gone).
static func find(target_id: String, items: Array) -> Dictionary:
	var p := parse(target_id)
	if p.is_empty():
		return {}
	if p["scope"] != "item":
		for t in site_targets():
			if str(t["id"]) == target_id:
				return t
		return {}
	for it in items:
		if it is Dictionary and str(it.get("id", "")) == str(p["item_id"]):
			var itype := str(it.get("type", ""))
			for f in ITEM_FIELDS.get(itype, []):
				if str(f["field"]) == str(p["field"]):
					var t := _mk(target_id, f, str(TYPE_GROUPS.get(itype, "Other")), "item", str(p["item_id"]), itype)
					t["item_label"] = item_label(it)
					t["label"] = "%s — %s" % [item_label(it), f["label"]]
					return t
	return {}


static func item_label(it: Dictionary) -> String:
	var n := str(it.get("label", it.get("name", ""))).strip_edges()
	if n.is_empty():
		n = UiText.from_id(str(it.get("type", "node")))
	return n


static func _mk(id: String, f: Dictionary, group: String, scope: String, iid: String, itype: String) -> Dictionary:
	return {"id": id, "label": str(f["label"]), "group": group, "unit": str(f["unit"]),
		"kind": str(f["kind"]), "scope": scope, "item_id": iid, "field": str(f["field"]),
		"item_type": itype}
