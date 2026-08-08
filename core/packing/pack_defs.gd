class_name PackDefs
extends RefCounted
## Reusable pack definitions ("kits") — PACKING_PLAN.md Phase 3, mirroring
## GraphComponentDefs: a curated, stampable description of how a whole
## system packs, as a LIST of PackTree units. A def is a list, not a single
## unit, because real kits split across handling units — the StarShade's
## 18-panel stack physically cannot share a 2'-tall crate with the folded
## frame (the dims refuse), and forcing one root box would just make the
## panels "escape" loose on every solve.
##
## A def: {id, label, notes, units: [<PackTree unit>]}. `realize()` returns
## deep copies (mutating a realized tree never edits the def) and resolves
## `def_ref` nodes — {def_ref: "<id>"} splices another def's units inline —
## with a visited-set guard so def cycles terminate instead of recursing.
##
## Builtins live here; user defs persist to user://pack_defs.json.
## (Capturing a def from live world state, the way Save-as-Component does,
## is deferred to the packing-modal phase.)

const USER_PATH := "user://pack_defs.json"


## The builtin kits. StarShade mirrors the graph's 3-level component tree
## (array / inverter / bank) as its PHYSICAL counterpart: a 4x8 crate with
## the folded frame + hardware, and the strapped panel stack alongside.
static func builtin_defs() -> Array:
	return [
		{
			"id": "starshade_kit", "label": "StarShade Kit",
			"notes": "4x8 crate (folded frame + hardware) + strapped 18-panel stack.",
			"units": [
				{"label": "StarShade crate", "container_id": "crate_8x4", "qty": 1,
					"contents": [
						{"label": "Folded frame bundle", "qty": 1, "spec": {
							"w_m": 2.30, "d_m": 1.00, "h_m": 0.30, "mass_kg": 160.0,
							"form": "folded", "source": "estimated", "stackable": true}},
						{"label": "Bracket box", "qty": 1, "spec": {
							"w_m": 0.40, "d_m": 0.30, "h_m": 0.15, "mass_kg": 30.0,
							"form": "crate", "source": "estimated"}},
						{"label": "Bolt + fastener box", "qty": 1, "spec": {
							"w_m": 0.25, "d_m": 0.20, "h_m": 0.12, "mass_kg": 12.0,
							"form": "crate", "source": "estimated"}},
					]},
				{"label": "Panel stack (18, strapped)", "qty": 1, "spec": {
					"w_m": 1.65, "d_m": 0.99, "h_m": 0.85, "mass_kg": 284.0,
					"form": "panel_stack", "source": "estimated",
					"stackable": false, "this_side_up": true}},
			],
		},
		{
			"id": "solar_starter_kit", "label": "Solar Starter Kit (12 V)",
			"notes": "One tote: trainer controller + battery + cables.",
			"units": [
				{"label": "Solar Starter tote", "container_id": "tote_27gal", "qty": 1,
					"contents": [
						{"label": "PWM controller", "qty": 1, "spec": {
							"w_m": 0.20, "d_m": 0.15, "h_m": 0.08, "mass_kg": 0.9,
							"form": "crate", "source": "estimated"}},
						{"label": "Battery 12V 100Ah", "qty": 1, "spec": {
							"w_m": 0.33, "d_m": 0.17, "h_m": 0.22, "mass_kg": 13.0,
							"form": "crate", "source": "curated",
							"this_side_up": true}},
						{"label": "Cables + connectors", "qty": 1, "spec": {
							"w_m": 0.26, "d_m": 0.20, "h_m": 0.15, "mass_kg": 4.0,
							"form": "loose", "source": "estimated"}},
					]},
			],
		},
	]


static func all_defs() -> Array:
	var out := builtin_defs()
	out.append_array(load_user())
	return out


static func find(def_id: String) -> Dictionary:
	for d in all_defs():
		if str((d as Dictionary).get("id", "")) == def_id:
			return d
	return {}


## Deep-copied, def_ref-resolved unit list for a def. `_seen` guards
## def-reference cycles (a def stamping itself resolves to []).
static func realize(def_id: String, _seen: Dictionary = {}) -> Array:
	if _seen.has(def_id):
		return []
	var def := find(def_id)
	if def.is_empty():
		return []
	_seen[def_id] = true
	var out: Array = []
	for unit in def.get("units", []):
		if unit is Dictionary:
			out.append_array(_resolve_unit((unit as Dictionary).duplicate(true), _seen))
	_seen.erase(def_id)
	return out


## One authored unit → one or more realized units (a def_ref splices).
static func _resolve_unit(unit: Dictionary, seen: Dictionary) -> Array:
	if unit.has("def_ref"):
		var spliced := realize(str(unit.get("def_ref", "")), seen)
		if unit.has("qty") and spliced.size() == 1:
			(spliced[0] as Dictionary)["qty"] = int(unit.get("qty", 1))
		return spliced
	if unit.has("contents"):
		var resolved: Array = []
		for child in unit.get("contents", []):
			if child is Dictionary:
				resolved.append_array(_resolve_unit(child as Dictionary, seen))
		unit["contents"] = resolved
	return [unit]


static func load_user() -> Array:
	if not FileAccess.file_exists(USER_PATH):
		return []
	var f := FileAccess.open(USER_PATH, FileAccess.READ)
	if f == null:
		return []
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if parsed is Dictionary and (parsed as Dictionary).get("defs") is Array:
		return (parsed as Dictionary)["defs"]
	return []


static func save_user(defs: Array) -> bool:
	var f := FileAccess.open(USER_PATH, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify({"version": 1, "defs": defs}, "\t"))
	return true
