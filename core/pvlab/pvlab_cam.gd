class_name PvLabCam
extends RefCounted

## Files for a Solar designer array: the bill of materials (CSV), the
## string diagram (SVG, the modules in plan with each string's wiring and
## the electrical table), and the whole design (JSON). Pure, plus write_all.


static func bom_csv(d: Dictionary) -> String:
	var lines := PackedStringArray(["group,item,qty,unit,length_m,cost_usd,kg"])
	for r in d["bom"]["rows"]:
		lines.append("%s,\"%s\",%d,%s,%.2f,%.2f,%.2f" % [str(r["group"]), str(r["item"]).replace("\"", "'"),
			int(r["qty"]), str(r["unit"]), float(r["length_m"]), float(r["cost"]), float(r["kg"])])
	lines.append("total,,,,,%.2f,%.2f" % [float(d["bom"]["cost_usd"]), float(d["bom"]["mass_kg"])])
	return "\n".join(lines) + "\n"


## The modules in plan (array frame x across, z the way it faces), each
## string's links drawn and its modules numbered in wiring order.
static func strings_svg(d: Dictionary) -> String:
	var lay: Dictionary = d["layout"]
	var fp: Rect2 = lay["footprint"]
	var pad := 0.6
	var scale := 120.0
	var w := (fp.size.x + pad * 2.0) * scale
	var h := (fp.size.y + pad * 2.0) * scale + 30.0 * float((d["strings"] as Array).size() + 3)
	var out := PackedStringArray()
	out.append("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%.0f\" height=\"%.0f\" font-family=\"sans-serif\" font-size=\"13\">" % [w, h])
	var colors := string_colors((d["strings"] as Array).size())
	var string_of := {}
	var pos_in := {}
	for si in (d["strings"] as Array).size():
		var st: Array = d["strings"][si]
		for k in st.size():
			string_of[int(st[k])] = si
			pos_in[int(st[k])] = k + 1
	var m: Dictionary = d["module"]
	var mw := float(m["dims_mm"]["w"]) * 0.001
	var mh := float(m["dims_mm"]["h"]) * 0.001
	var to_px := func(p: Vector3) -> Vector2:
		return Vector2((p.x - fp.position.x + pad) * scale, (p.z - fp.position.y + pad) * scale)
	for p in lay["panels"]:
		var xf := PvLabArray.panel_xf(lay, p, 0.0)
		var corners: Array = []
		for c in [Vector3(-mw, 0, -mh), Vector3(mw, 0, -mh), Vector3(mw, 0, mh), Vector3(-mw, 0, mh)]:
			corners.append(to_px.call(xf * (c * 0.5)))
		var pts := " ".join(corners.map(func(v): return "%.1f,%.1f" % [v.x, v.y]))
		var idx := int(p["index"])
		var col := "#bbbbbb"
		if string_of.has(idx):
			col = (colors[int(string_of[idx])] as Color).to_html(false)
		out.append("<polygon points=\"%s\" fill=\"#%s\" fill-opacity=\"0.35\" stroke=\"#333\" stroke-width=\"1\"/>" % [pts, col])
		var cpx: Vector2 = to_px.call(xf.origin)
		var lbl := "S%d·%d" % [int(string_of[idx]) + 1, int(pos_in[idx])] if string_of.has(idx) else "—"
		out.append("<text x=\"%.1f\" y=\"%.1f\" text-anchor=\"middle\">%s</text>" % [cpx.x, cpx.y + 4.0, lbl])
	var leads: Array = d["wiring"]["leads"]
	for si in (d["wiring"]["strings"] as Array).size():
		var st2: Dictionary = d["wiring"]["strings"][si]
		for ln in st2["links"]:
			var a: Vector2 = to_px.call((leads[int(ln["from"])] as Dictionary)["plus"])
			var b: Vector2 = to_px.call((leads[int(ln["to"])] as Dictionary)["minus"])
			var dash := "" if bool(ln["reach"]) else " stroke-dasharray=\"6,4\""
			out.append("<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"#%s\" stroke-width=\"2.5\"%s/>" % [
				a.x, a.y, b.x, b.y, (colors[si] as Color).to_html(false), dash])
	var y := (fp.size.y + pad * 2.0) * scale + 24.0
	for si in (d["string_reports"] as Array).size():
		var r: Dictionary = d["string_reports"][si]
		out.append("<text x=\"12\" y=\"%.0f\" fill=\"#%s\">String %d: %d modules · Voc %.1f V (cold %.1f V) · Vmp %.1f V · Isc %.2f A · %.0f W</text>" % [
			y, (colors[si] as Color).to_html(false), si + 1, int(r["n"]), float(r["voc"]),
			float(r["window"]["voc_cold"]), float(r["vmp"]), float(r["isc"]), float(r["wmp"])])
		y += 22.0
	out.append("<text x=\"12\" y=\"%.0f\">%s · dashed = needs an extension cable</text>" % [y + 6.0, str(d["name"])])
	out.append("</svg>")
	return "\n".join(out) + "\n"


## Distinct colours for n strings.
static func string_colors(n: int) -> Array:
	var out: Array = []
	for i in maxi(n, 1):
		out.append(Color.from_hsv(fposmod(0.08 + float(i) * 0.618034, 1.0), 0.75, 0.95))
	return out


static func write_all(d: Dictionary, dir: String) -> Dictionary:
	var err := DirAccess.make_dir_recursive_absolute(dir)
	if err != OK and not DirAccess.dir_exists_absolute(dir):
		return {"ok": false, "error": "cannot make %s" % dir, "files": []}
	var base := DomeLabCam.safe_name(str(d["name"]))
	var files := {
		"%s_bom.csv" % base: bom_csv(d),
		"%s_strings.svg" % base: strings_svg(d),
		"%s_design.json" % base: JSON.stringify(PvLabSpec.to_json_safe(d["spec"]), "\t"),
	}
	var written: Array = []
	for fname in files:
		var path := dir.path_join(str(fname))
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			return {"ok": false, "error": "cannot write %s" % path, "files": written}
		f.store_string(str(files[fname]))
		f.close()
		written.append(path)
	return {"ok": true, "files": written}
