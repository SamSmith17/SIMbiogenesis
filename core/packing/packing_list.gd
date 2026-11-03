class_name PackingList
extends RefCounted

## Packing lists PER SPACE: the container (what goes in, in load order, and
## the reverse unload order), every pallet (what is strapped on it, bottom
## layer first) and every crate / bundle with parts (what is inside it). Each
## handling unit gets an ID that names where it lives — `C1-P03` is pallet 3
## in the container, `C1-P03-B02` the second box on it, `C1-U07` a loose unit
## — which is what goes on the printed label stuck to the box. A vehicle's
## cargo bay is `V1` (`V1-U02`) so a label never claims a container. Pure static so
## packing_selftest pins it offline; the Packing Lab hands the data in and
## writes the files (CSV + JSON + a printable HTML page with label cards).

const DEFAULT_DIR := "user://packing_lists"


## `entry` = ContainerCatalog entry; `units` = the solver's items (in pallet
## mode: PackPalletizer pallets then loose units); `placed` = the Lab's
## [{unit_idx, pos, size}] rows; `raw_units` = the handling units BEFORE
## palletizing (a pallet's placements index into it; pass [] when not
## palletized). Returns pure data (JSON-safe).
static func build(entry: Dictionary, units: Array, placed: Array,
		raw_units: Array = [], list_name: String = "") -> Dictionary:
	var cname := str(entry.get("label", "Container"))
	var sid := "V1" if str(entry.get("kind", "")) == "vehicle" else "C1"
	var rows: Array = []
	var placed_idx: Dictionary = {}
	for p: Variant in placed:
		var d := p as Dictionary
		var idx := int(d.get("unit_idx", -1))
		if idx < 0 or idx >= units.size():
			continue
		placed_idx[idx] = true
		var pos: Vector3 = d.get("pos", Vector3.ZERO)
		var size: Vector3 = d.get("size", Vector3.ZERO)
		rows.append({"unit_idx": idx, "pos": pos, "size": size})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var pa: Vector3 = a["pos"]
		var pb: Vector3 = b["pos"]
		if absf(pa.z - pb.z) > 0.001:
			return pa.z < pb.z
		if absf(pa.y - pb.y) > 0.001:
			return pa.y < pb.y
		return pa.x < pb.x)

	# IDs: pallets numbered P01.. in load order, loose units U01..
	var ids: Dictionary = {}   # unit idx → id
	var n_p := 0
	var n_u := 0
	for r: Variant in rows:
		var idx := int((r as Dictionary)["unit_idx"])
		var u: Dictionary = units[idx] as Dictionary
		if bool(u.get("pallet", false)):
			n_p += 1
			ids[idx] = "%s-P%02d" % [sid, n_p]
		else:
			n_u += 1
			ids[idx] = "%s-U%02d" % [sid, n_u]
	var not_loaded: Array = []
	for i: int in units.size():
		if placed_idx.has(i):
			continue
		var u: Dictionary = units[i] as Dictionary
		n_u += 1
		ids[i] = "X-U%02d" % n_u
		not_loaded.append(_unit_row(ids[i], u, Vector3(
			float(u.get("w_m", 0.0)), float(u.get("h_m", 0.0)),
			float(u.get("d_m", 0.0)))))

	var spaces: Array = []
	var cards: Array = []
	var c_rows: Array = []
	var total_kg := 0.0
	for i: int in rows.size():
		var r: Dictionary = rows[i]
		var idx := int(r["unit_idx"])
		var u: Dictionary = units[idx] as Dictionary
		var row := _unit_row(ids[idx], u, r["size"])
		row["load_seq"] = i + 1
		row["unload_seq"] = rows.size() - i
		var pos: Vector3 = r["pos"]
		row["pos_m"] = [snappedf(pos.x, 0.01), snappedf(pos.y, 0.01), snappedf(pos.z, 0.01)]
		c_rows.append(row)
		total_kg += maxf(float(u.get("mass_kg", 0.0)), 0.0)
		cards.append(_card(row, cname, ""))
	spaces.append({
		"kind": "container", "id": sid, "label": cname,
		"rows": c_rows, "not_loaded": not_loaded,
		"total_kg": total_kg,
		"payload_kg": float(entry.get("payload_kg", 0.0)),
	})

	# Pallets: what is on each, bottom layer first.
	for r: Variant in rows:
		var idx := int((r as Dictionary)["unit_idx"])
		var u: Dictionary = units[idx] as Dictionary
		if not bool(u.get("pallet", false)):
			continue
		var pid: String = ids[idx]
		var pls: Array = (u.get("placements", []) as Array).duplicate()
		pls.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			var pa: Vector3 = a.get("pos", Vector3.ZERO)
			var pb: Vector3 = b.get("pos", Vector3.ZERO)
			if absf(pa.y - pb.y) > 0.001:
				return pa.y < pb.y
			if absf(pa.z - pb.z) > 0.001:
				return pa.z < pb.z
			return pa.x < pb.x)
		var p_rows: Array = []
		for k: int in pls.size():
			var pl: Dictionary = pls[k] as Dictionary
			var ri := int(pl.get("unit", -1))
			var ru: Dictionary = (raw_units[ri] as Dictionary) \
				if ri >= 0 and ri < raw_units.size() else {"label": str(pl.get("label", "?"))}
			var bid := "%s-B%02d" % [pid, k + 1]
			var prow := _unit_row(bid, ru, pl.get("size", Vector3.ZERO))
			prow["layer_seq"] = k + 1
			p_rows.append(prow)
			cards.append(_card(prow, cname, pid))
			_add_crate_space(spaces, bid, ru)
		spaces.append({
			"kind": "pallet", "id": pid, "label": str(u.get("label", "Pallet")),
			"rows": p_rows, "total_kg": float(u.get("mass_kg", 0.0)),
			"notes": _notes(u),
		})
	# Loose units with parts (crates / bundles) get their own content list.
	for r: Variant in rows:
		var idx := int((r as Dictionary)["unit_idx"])
		var u: Dictionary = units[idx] as Dictionary
		if not bool(u.get("pallet", false)):
			_add_crate_space(spaces, ids[idx], u)

	return {
		"version": 1,
		"name": list_name if not list_name.is_empty() else cname,
		"container": cname,
		"spaces": spaces,
		"cards": cards,
	}


static func _add_crate_space(spaces: Array, id: String, u: Dictionary) -> void:
	var parts: Array = u.get("parts", []) as Array
	if parts.is_empty():
		return
	var rows: Array = []
	for p: Variant in parts:
		var pd := p as Dictionary
		rows.append({"label": str(pd.get("label", "?")), "qty": int(pd.get("qty", 1))})
	spaces.append({"kind": "crate", "id": id, "label": str(u.get("label", "?")),
		"rows": rows, "total_kg": float(u.get("mass_kg", 0.0)), "notes": _notes(u)})


static func _unit_row(id: String, u: Dictionary, size: Vector3) -> Dictionary:
	return {
		"id": id,
		"label": str(u.get("label", "?")),
		"size_m": [snappedf(size.x, 0.01), snappedf(size.y, 0.01), snappedf(size.z, 0.01)],
		"mass_kg": float(u.get("mass_kg", -1.0)),
		"notes": _notes(u),
	}


## Handling marks, in the words printed on a real label.
static func _notes(u: Dictionary) -> Array:
	var n: Array = []
	if bool(u.get("this_side_up", false)):
		n.append("THIS SIDE UP")
	if not bool(u.get("stackable", true)):
		n.append("DO NOT STACK")
	if bool(u.get("top_only", false)):
		n.append("TOP ONLY")
	if bool(u.get("fragile", false)):
		n.append("FRAGILE")
	if bool(u.get("overweight", false)):
		n.append("OVERWEIGHT")
	var h := str(u.get("handling", ""))
	if h.is_empty():
		h = PackKitter.handling_for(float(u.get("mass_kg", 0.0)))
	if bool(u.get("pallet", false)):
		h = "forklift"
	var lab := str(PackKitter.handling(h).get("label", ""))
	if not lab.is_empty():
		n.append(lab)
	return n


static func _card(row: Dictionary, container: String, on_pallet: String) -> Dictionary:
	return {
		"id": str(row["id"]),
		"label": str(row["label"]),
		"where": (on_pallet + " in " + container) if not on_pallet.is_empty() else container,
		"mass_kg": float(row.get("mass_kg", -1.0)),
		"notes": row.get("notes", []),
		"unload_seq": int(row.get("unload_seq", 0)),
	}


static func to_csv(doc: Dictionary) -> String:
	var lines: PackedStringArray = []
	lines.append("Packing list,%s" % PackManifestExport._csv_cell(str(doc.get("name", ""))))
	for s: Variant in doc.get("spaces", []):
		var sp := s as Dictionary
		lines.append("")
		lines.append("%s %s,%s" % [str(sp["kind"]).capitalize(), sp["id"],
			PackManifestExport._csv_cell(str(sp["label"]))])
		if str(sp["kind"]) == "crate":
			lines.append("Qty,Part")
			for r: Variant in sp["rows"]:
				lines.append("%d,%s" % [int(r["qty"]), PackManifestExport._csv_cell(str(r["label"]))])
			continue
		lines.append("Seq,Unload,ID,Item,Size,Mass kg,Notes")
		for r: Variant in sp["rows"]:
			var rd := r as Dictionary
			var seq := int(rd.get("load_seq", rd.get("layer_seq", 0)))
			lines.append("%d,%s,%s,%s,%s,%s,%s" % [seq,
				str(rd.get("unload_seq", "")), rd["id"],
				PackManifestExport._csv_cell(str(rd["label"])),
				PackManifestExport._dims_cm(rd["size_m"]),
				_kg(float(rd["mass_kg"])),
				PackManifestExport._csv_cell(" / ".join(PackedStringArray(rd["notes"])))])
		for r: Variant in sp.get("not_loaded", []):
			var rd := r as Dictionary
			lines.append("NOT LOADED,,%s,%s,%s,%s," % [rd["id"],
				PackManifestExport._csv_cell(str(rd["label"])),
				PackManifestExport._dims_cm(rd["size_m"]), _kg(float(rd["mass_kg"]))])
	return "\n".join(lines) + "\n"


static func _kg(m: float) -> String:
	return "%.1f" % m if m > 0.0 else "?"


static func _esc(s: String) -> String:
	return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")


## A page to print: one table per space, then cut-out label cards.
static func to_html(doc: Dictionary) -> String:
	var h: PackedStringArray = []
	h.append("<!doctype html><html><head><meta charset=\"utf-8\"><title>%s</title>" % _esc(str(doc.get("name", ""))))
	h.append("<style>body{font-family:sans-serif;font-size:12px}table{border-collapse:collapse;margin:8px 0 18px}"
		+ "td,th{border:1px solid #888;padding:3px 6px}th{background:#eee}.cards{display:flex;flex-wrap:wrap;gap:8px}"
		+ ".card{border:2px solid #000;width:6.5cm;padding:6px;page-break-inside:avoid}.id{font-size:22px;font-weight:bold}"
		+ ".n{font-weight:bold;color:#b00}h2{page-break-before:auto}</style></head><body>")
	h.append("<h1>Packing list — %s</h1>" % _esc(str(doc.get("name", ""))))
	for s: Variant in doc.get("spaces", []):
		var sp := s as Dictionary
		h.append("<h2>%s %s — %s</h2>" % [_esc(str(sp["kind"]).capitalize()), _esc(str(sp["id"])), _esc(str(sp["label"]))])
		if str(sp["kind"]) == "crate":
			h.append("<table><tr><th>Qty</th><th>Part</th></tr>")
			for r: Variant in sp["rows"]:
				h.append("<tr><td>%d</td><td>%s</td></tr>" % [int(r["qty"]), _esc(str(r["label"]))])
			h.append("</table>")
			continue
		h.append("<table><tr><th>Seq</th><th>Unload</th><th>ID</th><th>Item</th><th>Size</th><th>kg</th><th>Notes</th></tr>")
		for r: Variant in sp["rows"]:
			var rd := r as Dictionary
			h.append("<tr><td>%d</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td class=\"n\">%s</td></tr>" % [
				int(rd.get("load_seq", rd.get("layer_seq", 0))), str(rd.get("unload_seq", "")),
				_esc(str(rd["id"])), _esc(str(rd["label"])),
				_esc(PackManifestExport._dims_cm(rd["size_m"])), _kg(float(rd["mass_kg"])),
				_esc(" · ".join(PackedStringArray(rd["notes"])))])
		for r: Variant in sp.get("not_loaded", []):
			var rd := r as Dictionary
			h.append("<tr><td colspan=\"2\" class=\"n\">NOT LOADED</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td></td></tr>" % [
				_esc(str(rd["id"])), _esc(str(rd["label"])),
				_esc(PackManifestExport._dims_cm(rd["size_m"])), _kg(float(rd["mass_kg"]))])
		h.append("</table><p>Total %s kg</p>" % _kg(float(sp.get("total_kg", 0.0))))
	h.append("<h2>Labels</h2><div class=\"cards\">")
	for c: Variant in doc.get("cards", []):
		var cd := c as Dictionary
		h.append("<div class=\"card\"><div class=\"id\">%s</div><div>%s</div><div>%s</div><div>%s kg%s</div><div class=\"n\">%s</div></div>" % [
			_esc(str(cd["id"])), _esc(str(cd["label"])), _esc(str(cd["where"])),
			_kg(float(cd["mass_kg"])),
			(" · unload #%d" % int(cd["unload_seq"])) if int(cd["unload_seq"]) > 0 else "",
			_esc(" · ".join(PackedStringArray(cd["notes"])))])
	h.append("</div></body></html>")
	return "\n".join(h)


static func safe_name(s: String) -> String:
	var out := ""
	for ch in s.to_lower():
		out += ch if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") else "_"
	return out.strip_edges() if not out.is_empty() else "list"


## Writes packing_list.csv / .json / .html under `dir`. Returns the folder
## or "" on failure.
static func write_folder(doc: Dictionary, dir: String) -> String:
	if DirAccess.make_dir_recursive_absolute(dir) != OK and not DirAccess.dir_exists_absolute(dir):
		return ""
	var files := {
		"packing_list.csv": to_csv(doc),
		"packing_list.json": JSON.stringify(doc, "  "),
		"packing_list.html": to_html(doc),
	}
	for f: String in files:
		var fa := FileAccess.open(dir.path_join(f), FileAccess.WRITE)
		if fa == null:
			return ""
		fa.store_string(str(files[f]))
		fa.close()
	return dir
