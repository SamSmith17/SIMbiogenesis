class_name PackManifestExport
extends RefCounted

## Printable packing manifest — PACKING_PLAN.md Phase 7's first slice: the
## document a real camp crew loads a truck from. Pure static (no UI, no HTTP)
## so packing_selftest can pin it offline; the Packing Lab owns the FileDialog
## and hands the data in (same split as LinkageBom / linkage_build_guide_modal,
## and the same export formats — CSV + JSON, no PDF in GDScript).
##
## LOAD ORDER is the useful column a screenshot of the Lab cannot give you:
## the solver fills from z=0 with the door at HIGH z, so the nose loads first
## and the manifest's sequence is exactly the order boxes go in — read it
## bottom-up to unload. Sort is z (depth into the truck) then y (floor before
## anything stacked on it) then x, which never asks a crew to stack onto a box
## that has not been placed yet.


## `entry` = ContainerCatalog entry; `units` = solver unit dicts (PackedSpec
## shape + label); `placed` = the Lab's [{unit_idx, pos: Vector3, size:
## Vector3}] rows (extra keys like `mesh` are ignored). Returns a pure-data
## Dictionary — Vector3s are flattened to [x, y, z] arrays so the result
## JSON-stringifies cleanly.
static func build(entry: Dictionary, units: Array, placed: Array) -> Dictionary:
	# Same axis mapping as the Lab: x = width across, y = height, z = load
	# length (door at high z).
	var inter: Dictionary = entry.get("interior", {}) as Dictionary
	var interior := Vector3(float(inter.get("w_m", 0.0)),
		float(inter.get("h_m", 0.0)), float(inter.get("l_m", 0.0)))
	var vol := interior.x * interior.y * interior.z

	var rows: Array = []
	var placed_idx: Dictionary = {}
	var placed_vol := 0.0
	var mass := 0.0
	var unknown := 0
	var moment := Vector3.ZERO
	for p: Variant in placed:
		var d := p as Dictionary
		var idx := int(d.get("unit_idx", -1))
		if idx < 0 or idx >= units.size():
			continue
		placed_idx[idx] = true
		var unit: Dictionary = units[idx] as Dictionary
		var pos: Vector3 = d.get("pos", Vector3.ZERO)
		var size: Vector3 = d.get("size", Vector3.ZERO)
		placed_vol += size.x * size.y * size.z
		var m := float(unit.get("mass_kg", -1.0))
		if m > 0.0:
			mass += m
			moment += (pos + size * 0.5) * m
		else:
			unknown += 1
		rows.append({
			"label": str(unit.get("label", "?")),
			"pos_m": [snappedf(pos.x, 0.01), snappedf(pos.y, 0.01), snappedf(pos.z, 0.01)],
			"size_m": [snappedf(size.x, 0.01), snappedf(size.y, 0.01), snappedf(size.z, 0.01)],
			"mass_kg": m if m > 0.0 else -1.0,
			"this_side_up": bool(unit.get("this_side_up", false)),
			"stackable": bool(unit.get("stackable", true)),
		})
	# Nose first, floor before stacked, then across — the physical load order.
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var pa: Array = a["pos_m"]
		var pb: Array = b["pos_m"]
		if absf(float(pa[2]) - float(pb[2])) > 0.001:
			return float(pa[2]) < float(pb[2])
		if absf(float(pa[1]) - float(pb[1])) > 0.001:
			return float(pa[1]) < float(pb[1])
		return float(pa[0]) < float(pb[0]))
	for i: int in rows.size():
		(rows[i] as Dictionary)["load_seq"] = i + 1

	var unplaced: Array = []
	for i: int in units.size():
		if placed_idx.has(i):
			continue
		var unit: Dictionary = units[i] as Dictionary
		unplaced.append({
			"label": str(unit.get("label", "?")),
			"size_m": [snappedf(float(unit.get("w_m", 0.0)), 0.01),
				snappedf(float(unit.get("d_m", 0.0)), 0.01),
				snappedf(float(unit.get("h_m", 0.0)), 0.01)],
			"mass_kg": float(unit.get("mass_kg", -1.0)),
			"fits_door": ContainerCatalog.fits_through_door(entry, unit),
		})

	var payload := float(entry.get("payload_kg", 0.0))
	var com := (moment / mass) if mass > 0.0 else Vector3.ZERO
	return {
		"version": 1,
		"container": {
			"id": str(entry.get("id", "")),
			"label": str(entry.get("label", "?")),
			"interior_m": [snappedf(interior.x, 0.01), snappedf(interior.y, 0.01),
				snappedf(interior.z, 0.01)],
			"payload_kg": payload,
		},
		"loaded": rows,
		"unplaced": unplaced,
		"totals": {
			"placed_count": rows.size(),
			"unit_count": units.size(),
			"fill_frac": (placed_vol / vol) if vol > 0.0 else 0.0,
			"mass_kg": mass,
			"unweighed_count": unknown,
			"payload_ok": payload <= 0.0 or mass <= payload,
			# Fraction of the load length toward the DOOR end — the Lab's
			# tongue-weight / tail-heavy number, same convention.
			"com_len_frac": clampf(com.z / interior.z, 0.0, 1.0) \
				if mass > 0.0 and interior.z > 0.0 else 0.0,
		},
	}


static func _csv_cell(v: String) -> String:
	if v.contains(",") or v.contains("\""):
		return "\"%s\"" % v.replace("\"", "\"\"")
	return v


static func _dims_cm(size_m: Array) -> String:
	return "%d × %d × %d cm" % [roundi(float(size_m[0]) * 100.0),
		roundi(float(size_m[1]) * 100.0), roundi(float(size_m[2]) * 100.0)]


## Spreadsheet form (LinkageBom.to_csv precedent): a header block, the load
## order table, the didn't-fit table, and totals. Prints on one page for a
## typical camp load; unload by reading the load table bottom-up.
static func to_csv(manifest: Dictionary) -> String:
	var c: Dictionary = manifest.get("container", {}) as Dictionary
	var t: Dictionary = manifest.get("totals", {}) as Dictionary
	var out := "PACKING MANIFEST,%s\n" % _csv_cell(str(c.get("label", "?")))
	out += "Interior,%s\n" % _dims_cm(c.get("interior_m", [0, 0, 0]) as Array)
	var payload := float(c.get("payload_kg", 0.0))
	if payload > 0.0:
		out += "Payload limit,%.0f kg\n" % payload
	out += "\nLOAD ORDER (nose first; unload bottom-up)\n"
	out += "Seq,Item,Size,Mass kg,Depth-in m,Height m,Across m,Notes\n"
	for row: Variant in (manifest.get("loaded", []) as Array):
		var r := row as Dictionary
		var pos: Array = r.get("pos_m", [0, 0, 0]) as Array
		var m := float(r.get("mass_kg", -1.0))
		var notes: Array = []
		if bool(r.get("this_side_up", false)):
			notes.append("THIS SIDE UP")
		if not bool(r.get("stackable", true)):
			notes.append("do not stack on")
		out += "%d,%s,%s,%s,%.2f,%.2f,%.2f,%s\n" % [
			int(r.get("load_seq", 0)), _csv_cell(str(r.get("label", "?"))),
			_dims_cm(r.get("size_m", [0, 0, 0]) as Array),
			("%.1f" % m) if m > 0.0 else "?",
			float(pos[2]), float(pos[1]), float(pos[0]),
			_csv_cell(" / ".join(notes))]
	var unplaced: Array = manifest.get("unplaced", []) as Array
	if not unplaced.is_empty():
		out += "\nNOT LOADED\n"
		out += "Item,Size,Mass kg,Fits door\n"
		for row: Variant in unplaced:
			var r := row as Dictionary
			var m := float(r.get("mass_kg", -1.0))
			out += "%s,%s,%s,%s\n" % [_csv_cell(str(r.get("label", "?"))),
				_dims_cm(r.get("size_m", [0, 0, 0]) as Array),
				("%.1f" % m) if m > 0.0 else "?",
				"yes" if bool(r.get("fits_door", true)) else "NO"]
	out += "\nTOTALS\n"
	out += "Loaded,%d of %d\n" % [int(t.get("placed_count", 0)), int(t.get("unit_count", 0))]
	out += "Fill,%d%%\n" % roundi(float(t.get("fill_frac", 0.0)) * 100.0)
	var mass := float(t.get("mass_kg", 0.0))
	out += "Load mass,%.0f kg (%.0f lb)\n" % [mass, mass * 2.20462]
	if int(t.get("unweighed_count", 0)) > 0:
		out += "Unweighed items,%d\n" % int(t.get("unweighed_count", 0))
	if payload > 0.0:
		out += "Payload check,%s\n" % ("OK" if bool(t.get("payload_ok", true)) else "OVER PAYLOAD")
	out += "Load centre,%d%% toward the door\n" % roundi(float(t.get("com_len_frac", 0.0)) * 100.0)
	return out
