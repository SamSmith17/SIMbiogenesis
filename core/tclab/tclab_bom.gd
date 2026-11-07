class_name TcBom
extends RefCounted

## The bill of materials of a solved TC assembly: every part grouped by what
## it is, one gasket and one clamp per clamp joint, the spool cut list, and
## totals. Masses are computed from the parts' own geometry (TcParts); no
## prices yet (catalogue prices vary too much to state without a source).

static func compute(spec: Dictionary, res: Dictionary) -> Dictionary:
	var rows := {}
	var mass := 0.0
	var vol := 0.0
	var mat := str(TcSpec.MATERIALS.get(str(spec.get("material", "ss304")), "304 stainless"))
	for id in res.get("order", []):
		var pd: Dictionary = res["parts"].get(id, {})
		if pd.is_empty():
			continue
		var b: Dictionary = pd["built"]
		var key := str(b["label"])
		if not rows.has(key):
			rows[key] = {"group": "Fittings", "item": key, "spec": "%s, %s" % [str(b["designation"]), mat],
				"qty": 0, "each_kg": float(b["mass_kg"]), "ids": []}
		rows[key]["qty"] = int(rows[key]["qty"]) + 1
		(rows[key]["ids"] as Array).append(id)
		mass += float(b["mass_kg"])
		vol += float(b["volume_l"])
	var gaskets := {}
	var clamps := {}
	for jd in res.get("joints", []):
		if str(jd["kind"]) != "tc":
			continue
		var cls := TcStandards.clamp_class(str(jd["size"]))
		var sz := "½–¾\"" if cls == "mini" else TcStandards.size_label(cls)
		var gk := "%s %s gasket" % [sz, str(TcStandards.GASKETS[str(jd["gasket"])]["label"])]
		gaskets[gk] = int(gaskets.get(gk, 0)) + 1
		var ck := "%s %s clamp" % [sz, str(TcStandards.CLAMPS[str(jd["clamp"])]["label"]).get_slice(" (", 0).to_lower()]
		clamps[ck] = int(clamps.get(ck, 0)) + 1
	var out: Array = []
	var keys := rows.keys()
	keys.sort()
	for k in keys:
		out.append(rows[k])
	for k in gaskets:
		out.append({"group": "Gaskets", "item": k, "spec": "sanitary clamp gasket", "qty": gaskets[k], "each_kg": 0.0, "ids": []})
	for k in clamps:
		out.append({"group": "Clamps", "item": k, "spec": "304 stainless", "qty": clamps[k], "each_kg": 0.0, "ids": []})
	var cuts: Array = []
	for p in spec.get("parts", []):
		if str(p["type"]) == "spool":
			var L := float((res.get("fit", {}) as Dictionary).get(str(p["id"]), p["params"]["length_mm"]))
			cuts.append({"id": str(p["id"]), "size": str(p["size"]), "length_mm": L})
	return {"rows": out, "mass_kg": mass, "volume_l": vol, "cuts": cuts,
		"gaskets": _sum(gaskets), "clamps": _sum(clamps), "parts": (res.get("order", []) as Array).size()}


static func _sum(d: Dictionary) -> int:
	var n := 0
	for k in d:
		n += int(d[k])
	return n


static func to_csv(bom: Dictionary) -> String:
	var lines := PackedStringArray(["group,item,spec,qty,each_kg"])
	for r in bom["rows"]:
		lines.append("%s,\"%s\",\"%s\",%d,%.3f" % [r["group"], str(r["item"]).replace("\"", "\"\""),
			str(r["spec"]).replace("\"", "\"\""), int(r["qty"]), float(r["each_kg"])])
	lines.append("")
	lines.append("spool cut list")
	lines.append("part,size,length_mm")
	for c in bom["cuts"]:
		lines.append("%s,%s,%.1f" % [c["id"], c["size"], float(c["length_mm"])])
	lines.append("")
	lines.append("total mass kg,%.2f" % float(bom["mass_kg"]))
	lines.append("wetted volume L,%.2f" % float(bom["volume_l"]))
	return "\n".join(lines) + "\n"
