class_name ToroidLabCam
extends RefCounted

## The toroid's fabrication files, written with DomeLabCam's DXF / SVG
## writers (same layers: OUTSIDE_CUT, INSIDE_CUT, FOLD, ETCH, ETCH_LABELS):
##   <name>_sheet_NN.dxf / .svg   the canopy pieces nested on each sheet,
##                                score lines with their fold angles
##   <name>_bend_<class>.svg      a full-size bending template per bent tube
##                                class: the tube's band at its radius, the
##                                chord, ticks every 100 mm along the
##                                centreline (lay the bent tube on it)
##   <name>_tubes.csv, _bom.csv, _cut_sheet.txt, _design.json


static func sheet_content(d: Dictionary, idx: int) -> Dictionary:
	return ToroidLabCanopy.sheet_content(d["canopy"], idx)


## A bending template for one tube class, millimetres, the arc's chord along
## the bottom of the page.
static func bend_template(d: Dictionary, c: Dictionary) -> Dictionary:
	var od := float(ToroidLabMaterials.tube(str(d["spec"]["tube"]["material"]))["od_mm"])
	var R := float(c["bend_r_m"]) * 1000.0
	var ang := deg_to_rad(float(c["bend_deg"]))
	var margin := 40.0
	var half := ang * 0.5
	var ro := R + od * 0.5
	var ri := R - od * 0.5
	# Centre of curvature below the page; the arc's apex at the top.
	var rise_o := ro * (1.0 - cos(half))
	var cx := ro * sin(half) + margin
	var cy := margin + od - ro * cos(half) + 0.0
	var centre := Vector2(cx, cy)
	var pt := func(rad: float, a: float) -> Vector2: return centre + Vector2(sin(a), cos(a)) * rad
	var o0: Vector2 = pt.call(ro, -half)
	var o1: Vector2 = pt.call(ro, half)
	var i1: Vector2 = pt.call(ri, half)
	var i0: Vector2 = pt.call(ri, -half)
	var b := tan(ang / 4.0)
	var band := FlatpackProfile.make_ring(PackedVector2Array([o0, o1, i1, i0]), PackedFloat64Array([-b, 0.0, b, 0.0]))
	var w := cx * 2.0
	var h := margin * 2.0 + od + rise_o
	var etch: Array = []
	var a0: Vector2 = pt.call(R, -half)
	var a1: Vector2 = pt.call(R, half)
	etch.append({"a": a0, "b": a1})
	var L := R * ang
	var step := 100.0
	var s := 0.0
	while s <= L + 1e-6:
		var a := -half + s / R
		etch.append({"a": pt.call(R - od, a), "b": pt.call(R + od, a)})
		s += step
	var labels := [{"p": Vector2(cx, margin * 0.5 + 0.0), "size": 12.0, "rot": 0.0,
		"text": "%s ×%d  R %.0f mm  %.1f°  arc %.0f mm  chord %.0f mm" % [str(c["label"]), int(c["count"]), R,
			float(c["bend_deg"]), L, float(c["chord_m"]) * 1000.0]}]
	return {"w": w, "h": maxf(h, margin * 3.0), "outside": [band], "inside": [], "fold": [], "etch": etch,
		"labels": labels}


static func write_all(d: Dictionary, dir: String) -> Dictionary:
	var s: Dictionary = d["spec"]
	var units := str(s["fabrication"]["units"])
	var err := DirAccess.make_dir_recursive_absolute(dir)
	if err != OK and not DirAccess.dir_exists_absolute(dir):
		return {"ok": false, "files": [], "error": "could not create %s" % dir}
	var files: Array = []
	var base := DomeLabCam.safe_name(str(d["name"]))
	var cn: Dictionary = d["canopy"]
	# Every sheet carries the same two pieces; write the distinct layouts once
	# each (sheet 1 is enough when all are alike, but a mixed last sheet is not).
	var written := {}
	for sh in (cn.get("nest", {}) as Dictionary).get("sheets", []):
		var idx := int(sh["index"])
		var sig := ",".join((sh["placements"] as Array).map(func(p): return str(p["id"]).get_slice("_", 0)))
		if written.has(sig):
			continue
		written[sig] = true
		var c := sheet_content(d, idx)
		var stem := "%s_sheet_%02d" % [base, idx + 1]
		for pair in [[".dxf", DomeLabCam.dxf_document(c, units)], [".svg", DomeLabCam.svg_document(c, units, "%s — sheet %d (%s)" % [str(d["name"]), idx + 1, sig])]]:
			var path := dir.path_join(stem + str(pair[0]))
			if not _write(path, str(pair[1])):
				return {"ok": false, "files": files, "error": "could not write %s" % path}
			files.append(path)
	for c in (d["frame"] as Dictionary)["classes"]:
		if float(c["bend_r_m"]) <= 0.0 or float(c["bend_r_m"]) > 6.0:
			continue
		var content := bend_template(d, c)
		var path := dir.path_join("%s_bend_%s.svg" % [base, str(c["label"])])
		if not _write(path, DomeLabCam.svg_document(content, "mm", "Bend %s" % str(c["label"]))):
			return {"ok": false, "files": files, "error": "could not write %s" % path}
		files.append(path)
	for pair in [["_tubes.csv", ToroidLabBom.tubes_csv(d)], ["_bom.csv", ToroidLabBom.bom_csv(d)],
			["_cut_sheet.txt", ToroidLabBom.cut_sheet_text(d)],
			["_design.json", JSON.stringify(fabrication_json(d), "\t")]]:
		var path := dir.path_join(base + str(pair[0]))
		if not _write(path, str(pair[1])):
			return {"ok": false, "files": files, "error": "could not write %s" % path}
		files.append(path)
	return {"ok": true, "files": files, "error": ""}


## Everything a builder or another tool needs, JSON-safe.
static func fabrication_json(d: Dictionary) -> Dictionary:
	var fr: Dictionary = d["frame"]
	var rings: Array = []
	for r in fr["rings"]:
		rings.append({"index": r["index"], "name": r["name"], "deg": r["deg"], "radius_m": r["radius_m"], "y_m": r["y"],
			"on_node": r["on_node"]})
	var fits: Array = []
	for f in fr["fittings"]:
		var p: Vector3 = f["p"]
		fits.append({"type": f["type"], "p": [p.x, p.y, p.z], "rib": f["rib"], "ring": f["ring"]})
	var members: Array = []
	for m in fr["members"]:
		var pts: Array = []
		for q in (m["pts"] as PackedVector3Array):
			pts.append([snappedf(q.x, 0.0001), snappedf(q.y, 0.0001), snappedf(q.z, 0.0001)])
		members.append({"id": m["id"], "kind": m["kind"], "class": m["cls"], "len_m": m["len_m"], "pts": pts})
	var classes: Array = []
	for c in fr["classes"]:
		classes.append(c.duplicate())
	var so: Dictionary = d["solar"]
	var sm: Dictionary = (so["summary"] as Dictionary).duplicate()
	if sm.has("avg_normal"):
		var n: Vector3 = sm["avg_normal"]
		sm["avg_normal"] = [n.x, n.y, n.z]
	var bom: Dictionary = (d["bom"] as Dictionary).duplicate(true)
	return {"name": d["name"], "spec": ToroidLabSpec.to_json_safe(d["spec"]), "torus": {"R_m": fr["R"], "r_m": fr["r"],
		"centre_h_m": fr["hc"], "segments": fr["n"]}, "rings": rings, "classes": classes, "members": members,
		"fittings": fits, "solar": sm, "bom": bom, "checks": d["checks"]}


static func _write(path: String, text: String) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(text)
	f.close()
	return true
