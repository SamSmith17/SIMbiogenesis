class_name PartInventory
extends RefCounted

## Per-map store of fabricated parts produced by Cartesian machines (CNC / 3D
## printer). This is the groundwork for the crafting mechanic: completed machine
## jobs credit parts here, and RecipeCatalog "spends" them to assemble larger
## structures (e.g. a recycled-plastic geodesic dome). Persisted per site as a
## user:// sidecar JSON keyed by lat/lon (same pattern as BuildingStyleLayer /
## user water), so a player's stock of hubs/beams survives reloads.

const VERSION := 1

## part_id -> {"label": String, "qty": int, "material_kind": String,
##             "mass_kg": float, "source": String}
var parts: Dictionary = {}


static func create_empty() -> PartInventory:
	var inv := PartInventory.new()
	inv.parts = {}
	return inv


func save_path_for_map(lat: float, lon: float) -> String:
	return WorldPaths.site_file("inventory", lat, lon)


func save(lat: float, lon: float) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://maps"))
	var f := FileAccess.open(save_path_for_map(lat, lon), FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(serialize()))


func load_for_map(lat: float, lon: float) -> bool:
	var path := save_path_for_map(lat, lon)
	if not FileAccess.file_exists(path):
		parts = {}
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		return false
	deserialize(parsed as Dictionary)
	return true


func serialize() -> Dictionary:
	return {"version": VERSION, "parts": parts.duplicate(true)}


func deserialize(data: Dictionary) -> void:
	parts = {}
	var raw: Variant = data.get("parts", {})
	if not (raw is Dictionary):
		return
	for pid in (raw as Dictionary):
		var rec: Variant = (raw as Dictionary)[pid]
		if rec is Dictionary:
			parts[str(pid)] = {
				"label": str((rec as Dictionary).get("label", str(pid))),
				"qty": int((rec as Dictionary).get("qty", 0)),
				"material_kind": str((rec as Dictionary).get("material_kind", "")),
				"mass_kg": float((rec as Dictionary).get("mass_kg", 0.0)),
				"source": str((rec as Dictionary).get("source", "")),
			}


func add_part(part_id: String, qty: int = 1, meta: Dictionary = {}) -> void:
	if part_id.is_empty() or qty <= 0:
		return
	if parts.has(part_id):
		parts[part_id]["qty"] = int(parts[part_id].get("qty", 0)) + qty
	else:
		parts[part_id] = {
			"label": str(meta.get("label", part_id)),
			"qty": qty,
			"material_kind": str(meta.get("material_kind", "")),
			"mass_kg": float(meta.get("mass_kg", 0.0)),
			"source": str(meta.get("source", "")),
		}


## Removes qty of a part; returns false (and changes nothing) if insufficient.
func remove_part(part_id: String, qty: int = 1) -> bool:
	if not has_part(part_id, qty):
		return false
	var remaining := int(parts[part_id].get("qty", 0)) - qty
	if remaining <= 0:
		parts.erase(part_id)
	else:
		parts[part_id]["qty"] = remaining
	return true


func count(part_id: String) -> int:
	return int(parts.get(part_id, {}).get("qty", 0)) if parts.has(part_id) else 0


func has_part(part_id: String, qty: int = 1) -> bool:
	return count(part_id) >= qty


func label_for(part_id: String) -> String:
	return str(parts.get(part_id, {}).get("label", part_id)) if parts.has(part_id) else part_id


func all_parts() -> Array:
	var out: Array = []
	for pid in parts:
		var rec: Dictionary = parts[pid]
		out.append({
			"id": str(pid),
			"label": str(rec.get("label", pid)),
			"qty": int(rec.get("qty", 0)),
			"material_kind": str(rec.get("material_kind", "")),
			"mass_kg": float(rec.get("mass_kg", 0.0)),
			"source": str(rec.get("source", "")),
		})
	out.sort_custom(func(a, b): return str(a.get("label", "")) < str(b.get("label", "")))
	return out


func is_empty() -> bool:
	return parts.is_empty()


## True when this stock entry is extruded beam feedstock (not a finished strut/hub).
static func is_beam_feedstock(part_id: String, label: String = "") -> bool:
	var pid := part_id.to_lower()
	if pid == "pp_beam" or pid.begins_with("pp_beam") \
			or pid.begins_with("recycled_plastic_beam"):
		return true
	# Finished dome parts are never feedstock.
	if pid.begins_with("dome_hub") or pid.begins_with("dome_strut"):
		return false
	var lbl := label.to_lower()
	return lbl.contains("recycled plastic beam") or (
		lbl.contains("beam") and not lbl.contains("strut") and not lbl.contains("hub"))


## Total qty of beam feedstock across matching part ids.
func count_beam_feedstock() -> int:
	var n := 0
	for pid in parts:
		var rec: Dictionary = parts[pid]
		if is_beam_feedstock(str(pid), str(rec.get("label", ""))):
			n += int(rec.get("qty", 0))
	return n


## Pick a beam part_id that can supply `qty` (prefers canonical pp_beam).
func pick_beam_feedstock(qty: int = 1) -> String:
	if has_part("pp_beam", qty):
		return "pp_beam"
	var fallback := ""
	for pid in parts:
		var rec: Dictionary = parts[pid]
		if not is_beam_feedstock(str(pid), str(rec.get("label", ""))):
			continue
		if int(rec.get("qty", 0)) >= qty:
			if fallback.is_empty():
				fallback = str(pid)
			# Prefer ids that look like beams over odd snake-case leftovers.
			if str(pid).begins_with("recycled_plastic_beam"):
				return str(pid)
	return fallback


## Consume beam feedstock; returns the part_id debited, or "" if short.
func consume_beam_feedstock(qty: int = 1) -> String:
	var pid := pick_beam_feedstock(qty)
	if pid.is_empty():
		return ""
	if not remove_part(pid, qty):
		return ""
	return pid
