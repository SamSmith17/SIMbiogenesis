class_name HaPresets
extends RefCounted
## One-click links for known devices (pure).
##
## A preset recognises a device in the entity catalog by one ANCHOR entity
## ("<domain>.<device>_<anchor>", the device part starting with
## `device_prefix`) and then maps the device's other entities
## ("<domain>.<device>_<suffix>") onto targets: site values directly, graph
## node fields onto a node the player picks. Only entities that exist in the
## catalog become links. These replace the 78 entity ids InverterBridge used
## to subscribe to by name, which only matched the original author's devices.

const PRESETS := [
	{
		"id": "ecoworthy",
		"label": "EcoWorthy inverter (ESP32 CAN bus)",
		"blurb": "The ESPHome CAN-bus bridge for EcoWorthy all-in-one inverters: battery, solar, load and today's solar.",
		"anchor_domain": "sensor", "anchor": "pv_input_power", "device_prefix": "canbus_esp32",
		"site": {
			"site.battery_soc": ["sensor", ["battery_soc_inverter", "battery_soc_calculated", "battery_soc"]],
			"site.solar_kw": ["sensor", ["pv_input_power"]],
			"site.load_kw": ["sensor", ["ac_output_power"]],
			"site.daily_solar_kwh": ["sensor", ["pv_generation_today"]],
		},
		"items": {
			"battery": {"soc": ["sensor", ["battery_soc_inverter", "battery_soc_calculated"]],
				"voltage": ["sensor", ["battery_voltage"]], "current": ["sensor", ["battery_current"]]},
			"panel": {"power": ["sensor", ["pv_input_power"]], "voltage": ["sensor", ["pv_input_voltage"]],
				"current": ["sensor", ["pv_input_current"]]},
			"controller": {"ac_power": ["sensor", ["ac_output_power"]], "voltage": ["sensor", ["ac_output_voltage"]],
				"current": ["sensor", ["ac_load_current"]]},
		},
	},
	{
		"id": "shelly4pm",
		"label": "Shelly Pro 4PM",
		"blurb": "A Shelly Pro 4PM's four channels: power, energy and the on / off switch of each.",
		# ESPHome-style names say "output_N", Home Assistant's Shelly
		# integration says "switch_N"; both are recognised.
		"anchor_domain": "switch", "anchor": ["output_0", "switch_0"], "device_prefix": "shellypro4pm",
		"site": {},
		"items": {
			"shelly4pm": {
				"c0_power": ["sensor", ["output_0_power", "switch_0_power"]], "c0_switch": ["switch", ["output_0", "switch_0"]], "c0_energy": ["sensor", ["output_0_energy", "switch_0_energy"]],
				"c1_power": ["sensor", ["output_1_power", "switch_1_power"]], "c1_switch": ["switch", ["output_1", "switch_1"]], "c1_energy": ["sensor", ["output_1_energy", "switch_1_energy"]],
				"c2_power": ["sensor", ["output_2_power", "switch_2_power"]], "c2_switch": ["switch", ["output_2", "switch_2"]], "c2_energy": ["sensor", ["output_2_energy", "switch_2_energy"]],
				"c3_power": ["sensor", ["output_3_power", "switch_3_power"]], "c3_switch": ["switch", ["output_3", "switch_3"]], "c3_energy": ["sensor", ["output_3_energy", "switch_3_energy"]],
			},
		},
	},
	{
		"id": "shelly_plug",
		"label": "Shelly plug / 1PM (one load)",
		"blurb": "A single Shelly relay or plug with power metering, linked to one load node.",
		"anchor_domain": "switch", "anchor": "", "device_prefix": "shelly", "exclude_prefix": "shellypro4pm",
		"site": {},
		"items": {
			"acload": {"power": ["sensor", ["power", "switch_0_power"]], "energy": ["sensor", ["energy", "switch_0_energy"]],
				"switch": ["switch", ["", "switch_0"]]},
		},
	},
]


static func find(id: String) -> Dictionary:
	for p in PRESETS:
		if str(p["id"]) == id:
			return p
	return {}


## The devices of a preset present in `entity_ids` (device name parts).
static func devices(preset: Dictionary, entity_ids: Array) -> Array:
	var dom := str(preset["anchor_domain"]) + "."
	var anchors: Array = preset["anchor"] if preset["anchor"] is Array else [str(preset["anchor"])]
	var pref := str(preset["device_prefix"])
	var excl := str(preset.get("exclude_prefix", ""))
	var out: Array = []
	for e in entity_ids:
		var s := str(e)
		if not s.begins_with(dom):
			continue
		var rest := s.substr(dom.length())
		if not rest.begins_with(pref) or (not excl.is_empty() and rest.begins_with(excl)):
			continue
		var dev := ""
		if str(anchors[0]).is_empty():
			# The switch names the device: switch.shellyplug_s_kitchen (gen 1)
			# or switch.shellyplus1pm_ab12_switch_0 (gen 2). A multi-channel
			# device's "_output_N" switches belong to its own preset.
			if rest.contains("_output_"):
				continue
			dev = rest.trim_suffix("_switch_0")
		else:
			for a in anchors:
				if rest.ends_with("_" + str(a)):
					dev = rest.substr(0, rest.length() - str(a).length() - 1)
					break
		if not dev.is_empty() and not out.has(dev):
			out.append(dev)
	out.sort()
	return out


## The links a preset would make: [{entity_id, target_id, label}] for the
## entities that exist. `item_for_type` = graph node type → node id ("" =
## skip that part).
static func plan(preset: Dictionary, device: String, item_for_type: Dictionary, entity_ids: Array) -> Array:
	var have := {}
	for e in entity_ids:
		have[str(e)] = true
	var out: Array = []
	var site: Dictionary = preset.get("site", {})
	for tid in site.keys():
		var eid := _pick(site[tid], device, have)
		if not eid.is_empty():
			out.append({"entity_id": eid, "target_id": str(tid)})
	var items: Dictionary = preset.get("items", {})
	for itype in items.keys():
		var iid := str(item_for_type.get(itype, ""))
		if iid.is_empty():
			continue
		var fields: Dictionary = items[itype]
		for f in fields.keys():
			var eid := _pick(fields[f], device, have)
			if not eid.is_empty():
				out.append({"entity_id": eid, "target_id": HaTargets.item_target_id(iid, str(f))})
	return out


## First existing "<domain>.<device>_<suffix>" (suffix "" = the device itself).
static func _pick(spec: Array, device: String, have: Dictionary) -> String:
	var dom := str(spec[0])
	for suf in spec[1]:
		var s := str(suf)
		var eid := "%s.%s" % [dom, device] if s.is_empty() else "%s.%s_%s" % [dom, device, s]
		if have.has(eid):
			return eid
	return ""
