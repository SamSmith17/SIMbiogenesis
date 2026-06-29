class_name CsvEntityMapper
extends RefCounted
## Maps CSV entity_id strings to SolarUI playback roles with autolink heuristics.

const ROLE_NONE := ""

const ROLES : Array[Dictionary] = [
	{"id": ROLE_NONE, "label": "(not linked)"},
	{"id": "battery_soc", "label": "Battery SOC (%)"},
	{"id": "solar", "label": "Solar Input (W)"},
	{"id": "load", "label": "Total AC Load (W)"},
	{"id": "daily_solar", "label": "Daily Solar (kWh)"},
	{"id": "daily_load", "label": "Daily Load (kWh)"},
	{"id": "battery_voltage", "label": "Battery Voltage (V)"},
	{"id": "battery_current", "label": "Battery Current (A)"},
	{"id": "pv_voltage", "label": "PV Voltage (V)"},
	{"id": "pv_current", "label": "PV Current (A)"},
	{"id": "ac_voltage", "label": "AC Output Voltage (V)"},
	{"id": "ac_frequency", "label": "AC Frequency (Hz)"},
]

## role_id -> entity_id (one CSV entity per in-game slot)
var role_to_entity: Dictionary = {}
## entity_id -> role_id (inverse, rebuilt on set)
var entity_to_role: Dictionary = {}


static func role_label(role_id: String) -> String:
	for r: Dictionary in ROLES:
		if str(r.get("id", "")) == role_id:
			return str(r.get("label", role_id))
	return role_id


static func autolink(entity_ids: Array) -> Dictionary:
	var out: Dictionary = {}
	var used_entities: Dictionary = {}
	var rules: Array[Dictionary] = [
		{"role": "battery_soc", "suffixes": ["battery_soc_inverter", "battery_soc_calculated"]},
		{"role": "solar", "suffixes": ["pv_input_power"]},
		{"role": "load", "suffixes": ["ac_output_power"]},
		{"role": "daily_solar", "suffixes": ["pv_generation_today"]},
		{"role": "daily_load", "suffixes": ["load_consumption_today"]},
		{"role": "battery_voltage", "suffixes": ["battery_voltage"]},
		{"role": "battery_current", "suffixes": ["battery_current"]},
		{"role": "pv_voltage", "suffixes": ["pv_input_voltage"]},
		{"role": "pv_current", "suffixes": ["pv_input_current"]},
		{"role": "ac_voltage", "suffixes": ["ac_output_voltage"]},
		{"role": "ac_frequency", "suffixes": ["ac_output_frequency"]},
	]
	for rule: Dictionary in rules:
		var role: String = str(rule.get("role", ""))
		if out.has(role):
			continue
		var suffixes: Array = rule.get("suffixes", []) as Array
		for eid_v: Variant in entity_ids:
			var eid: String = str(eid_v)
			if used_entities.has(eid):
				continue
			for suffix_v: Variant in suffixes:
				var suffix: String = str(suffix_v)
				if eid.ends_with(suffix) or ("/" + suffix) in eid or suffix in eid:
					out[role] = eid
					used_entities[eid] = true
					break
			if out.has(role):
				break
	return out


func set_role_mappings(mappings: Dictionary) -> void:
	role_to_entity.clear()
	entity_to_role.clear()
	for role_v: Variant in mappings.keys():
		var role: String = str(role_v)
		if role == ROLE_NONE:
			continue
		var eid: String = str(mappings[role_v]).strip_edges()
		if eid.is_empty():
			continue
		role_to_entity[role] = eid
		entity_to_role[eid] = role


func set_entity_role(entity_id: String, role_id: String) -> void:
	var eid := entity_id.strip_edges()
	if eid.is_empty():
		return
	# Remove any prior assignment for this role or entity.
	for role: String in role_to_entity.keys():
		if role_to_entity[role] == eid:
			role_to_entity.erase(role)
	if entity_to_role.has(eid):
		var old_role: String = str(entity_to_role[eid])
		if role_to_entity.get(old_role, "") == eid:
			role_to_entity.erase(old_role)
		entity_to_role.erase(eid)
	for role: String in role_to_entity.keys():
		if role == role_id and role_to_entity[role] != eid:
			role_to_entity.erase(role)
	if role_id == ROLE_NONE:
		return
	role_to_entity[role_id] = eid
	entity_to_role[eid] = role_id


func get_role_for_entity(entity_id: String) -> String:
	return str(entity_to_role.get(entity_id, ROLE_NONE))


func get_entity_for_role(role_id: String) -> String:
	return str(role_to_entity.get(role_id, ""))


func linked_role_count() -> int:
	return role_to_entity.size()
