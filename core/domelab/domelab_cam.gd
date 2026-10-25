class_name DomeLabCam
extends RefCounted

## Fabrication files for a solved dome: one DXF + SVG per nested panel sheet
## (outside cuts, holes, FOLD lines with the bend angle, labels), a drill
## template per hub type (plate hubs: the disc, the bolt circle, every arm's
## bearing and dip), a strut end template per strut class (the flattened
## tab with its hole and bend line), the strut schedule CSV, the bill of
## materials CSV, the whole design as JSON and the cut sheet. Pure static.
##
## Content shape (millimetres, y up, origin lower-left):
##   {w, h, outside: [ring], inside: [ring], fold: [{a, b, text}],
##    etch: [{a, b}], labels: [{p, text, size, rot}]}
## Rings are FlatpackProfile rings ({pts, bulge}). The DXF is R12 (AC1009)
## POLYLINE + TEXT on layers OUTSIDE_CUT / INSIDE_CUT / FOLD / ETCH /
## ETCH_LABELS / SHEET; the SVG is sized in real mm (or inches) with no
## fills, so an importer cuts only lines.

const LAYERS := {"SHEET": 8, "OUTSIDE_CUT": 1, "INSIDE_CUT": 5, "FOLD": 3, "ETCH": 4, "ETCH_LABELS": 2}
const SVG_COLORS := {"SHEET": "#7f7f7f", "OUTSIDE_CUT": "#d0021b", "INSIDE_CUT": "#1a5fd0", "FOLD": "#2a9d3a",
	"ETCH": "#b8860b", "ETCH_LABELS": "#555555"}
const IN := 25.4


# ---------------------------------------------------------------------------
# Content builders
# ---------------------------------------------------------------------------

static func sheet_content(d: Dictionary, sheet_index: int) -> Dictionary:
	var c := DomeLabPanels.sheet_content(d["panels"], sheet_index)
	c["etch"] = []
	return c


## A plate hub's drill template: the disc, the centre hole, one bolt hole per
## arm at the hub reach, an etched bearing line per arm with its azimuth and
## dip, and the label.
static func hub_template(d: Dictionary, t: Dictionary) -> Dictionary:
	var s: Dictionary = d["spec"]
	var hub: Dictionary = s["hub"]
	var reach := float(hub["reach_mm"])
	var bolt := DomeLabMaterials.bolt(str(hub["bolt"]))
	var hole := float(bolt["hole_mm"])
	var r := reach + 25.0
	var margin := 12.0
	var cen := Vector2(r + margin, r + margin)
	var out := {"w": 2.0 * (r + margin), "h": 2.0 * (r + margin), "outside": [], "inside": [], "fold": [],
		"etch": [], "labels": []}
	(out["outside"] as Array).append(FlatpackProfile.circle_ring(cen, r))
	(out["inside"] as Array).append(FlatpackProfile.circle_ring(cen, hole * 0.5))
	# Arms: the first at 0°, then the gaps round.
	var az := 0.0
	var gaps: Array = t["gaps"]
	var dips: Array = t["dips"]
	for k in gaps.size():
		var dir := Vector2(cos(az), sin(az))
		(out["inside"] as Array).append(FlatpackProfile.circle_ring(cen + dir * reach, hole * 0.5))
		(out["etch"] as Array).append({"a": cen + dir * (hole * 0.8), "b": cen + dir * (r - 3.0)})
		(out["labels"] as Array).append({"p": cen + dir * (r - 14.0), "text": "%.1f° ↓%.1f°" % [rad_to_deg(az),
			rad_to_deg(float(dips[k]))], "size": 5.0, "rot": 0.0})
		az += deg_to_rad(float(gaps[k]))
	(out["labels"] as Array).append({"p": cen + Vector2(0, -hole * 0.5 - 9.0), "text": "%s ×%d" % [str(t["label"]),
		int(t["count"])], "size": 7.0, "rot": 0.0})
	return out


## A conduit strut's end: the flattened tab (full width of the flattened
## tube), the hole at `hole_offset` from the cut, and the bend line.
static func strut_end_template(d: Dictionary, c: Dictionary) -> Dictionary:
	var s: Dictionary = d["spec"]
	var mat := DomeLabMaterials.strut(str(s["strut"]["material"]))
	var ends: Dictionary = s["ends"]
	var bolt := DomeLabMaterials.bolt(str(s["hub"]["bolt"]))
	var w := PI * float(mat.get("od_mm", 25.0)) * 0.5 if str(mat.get("kind", "")) == "tube" \
		else DomeLabMaterials.strut_width_mm(mat)
	var flat := float(ends["flatten_mm"])
	var hole_off := float(ends["hole_offset_mm"])
	var L := maxf(flat + 60.0, 160.0)
	var margin := 10.0
	var out := {"w": L + 2.0 * margin, "h": w + 2.0 * margin, "outside": [], "inside": [], "fold": [],
		"etch": [], "labels": []}
	var o := Vector2(margin, margin)
	(out["outside"] as Array).append(FlatpackProfile.rect_ring(L, w, o))
	(out["inside"] as Array).append(FlatpackProfile.circle_ring(o + Vector2(hole_off, w * 0.5),
		float(bolt["hole_mm"]) * 0.5))
	(out["fold"] as Array).append({"a": o + Vector2(flat, 0), "b": o + Vector2(flat, w),
		"text": "flatten to here · bend %s" % DomeLabSpec.fmt_deg(float(c["bend_b"]))})
	(out["labels"] as Array).append({"p": o + Vector2(L * 0.65, w * 0.5), "text": "%s ×%d  cut %s" % [
		str(c["label"]), int(c["count"]), DomeLabSpec.fmt_len(float(c["cut"]) * 1000.0, str(s["fabrication"]["units"]))],
		"size": 5.0, "rot": 0.0})
	return out


# ---------------------------------------------------------------------------
# DXF
# ---------------------------------------------------------------------------

static func _n(v: float) -> String:
	var t := "%.4f" % v
	if t.contains("."):
		t = t.rstrip("0").rstrip(".")
	return "0" if t == "-0" else t


static func _pair(code: int, value) -> String:
	return "%d\n%s\n" % [code, str(value)]


static func dxf_document(content: Dictionary, units: String = "mm") -> String:
	var k := 1.0 / IN if units == "in" else 1.0
	var w := float(content["w"]) * k
	var h := float(content["h"]) * k
	var o := ""
	o += _pair(0, "SECTION") + _pair(2, "HEADER")
	o += _pair(9, "$ACADVER") + _pair(1, "AC1009")
	o += _pair(9, "$INSUNITS") + _pair(70, 1 if units == "in" else 4)
	o += _pair(9, "$MEASUREMENT") + _pair(70, 0 if units == "in" else 1)
	o += _pair(9, "$EXTMIN") + _pair(10, "0") + _pair(20, "0") + _pair(30, "0")
	o += _pair(9, "$EXTMAX") + _pair(10, _n(w)) + _pair(20, _n(h)) + _pair(30, "0")
	o += _pair(0, "ENDSEC")
	o += _pair(0, "SECTION") + _pair(2, "TABLES")
	o += _pair(0, "TABLE") + _pair(2, "LTYPE") + _pair(70, 2)
	o += _pair(0, "LTYPE") + _pair(2, "CONTINUOUS") + _pair(70, 0) + _pair(3, "Solid line") \
		+ _pair(72, 65) + _pair(73, 0) + _pair(40, "0.0")
	o += _pair(0, "LTYPE") + _pair(2, "DASHED") + _pair(70, 0) + _pair(3, "Dashed") \
		+ _pair(72, 65) + _pair(73, 2) + _pair(40, "0.75") + _pair(49, "0.5") + _pair(49, "-0.25")
	o += _pair(0, "ENDTAB")
	o += _pair(0, "TABLE") + _pair(2, "LAYER") + _pair(70, LAYERS.size())
	for name in LAYERS:
		o += _pair(0, "LAYER") + _pair(2, name) + _pair(70, 0) + _pair(62, LAYERS[name]) \
			+ _pair(6, "DASHED" if name == "FOLD" else "CONTINUOUS")
	o += _pair(0, "ENDTAB") + _pair(0, "ENDSEC")
	o += _pair(0, "SECTION") + _pair(2, "ENTITIES")
	o += _dxf_poly(FlatpackProfile.rect_ring(float(content["w"]), float(content["h"])), "SHEET", k)
	for r in content["outside"]:
		o += _dxf_poly(r, "OUTSIDE_CUT", k)
	for r in content["inside"]:
		o += _dxf_poly(r, "INSIDE_CUT", k)
	for f in content.get("fold", []):
		o += _dxf_line(f["a"], f["b"], "FOLD", k)
		var mid: Vector2 = ((f["a"] as Vector2) + (f["b"] as Vector2)) * 0.5
		var dir: Vector2 = ((f["b"] as Vector2) - (f["a"] as Vector2))
		var rot := rad_to_deg(atan2(dir.y, dir.x))
		if rot > 90.0 or rot < -90.0:
			rot += 180.0
		o += _dxf_text(mid * k, str(f.get("text", "")), 4.0 * k, rot, "FOLD")
	for e in content.get("etch", []):
		o += _dxf_line(e["a"], e["b"], "ETCH", k)
	for lb in content.get("labels", []):
		o += _dxf_text((lb["p"] as Vector2) * k, str(lb["text"]), float(lb["size"]) * k, float(lb.get("rot", 0.0)),
			"ETCH_LABELS")
	o += _pair(0, "ENDSEC") + _pair(0, "EOF")
	return o


static func _dxf_poly(ring: Dictionary, layer: String, k: float) -> String:
	var pts: PackedVector2Array = ring["pts"]
	var bul: PackedFloat64Array = ring["bulge"]
	var o := _pair(0, "POLYLINE") + _pair(8, layer) + _pair(66, 1) + _pair(10, "0") + _pair(20, "0") \
		+ _pair(30, "0") + _pair(70, 1)
	for i in pts.size():
		o += _pair(0, "VERTEX") + _pair(8, layer) + _pair(10, _n(pts[i].x * k)) \
			+ _pair(20, _n(pts[i].y * k)) + _pair(30, "0")
		if i < bul.size() and absf(bul[i]) > 1e-9:
			o += _pair(42, "%.6f" % bul[i])
	o += _pair(0, "SEQEND") + _pair(8, layer)
	return o


static func _dxf_line(a: Vector2, b: Vector2, layer: String, k: float) -> String:
	return _pair(0, "LINE") + _pair(8, layer) + _pair(10, _n(a.x * k)) + _pair(20, _n(a.y * k)) + _pair(30, "0") \
		+ _pair(11, _n(b.x * k)) + _pair(21, _n(b.y * k)) + _pair(31, "0")


static func _dxf_text(p: Vector2, text: String, size: float, rot: float, layer: String) -> String:
	return _pair(0, "TEXT") + _pair(8, layer) + _pair(10, _n(p.x)) + _pair(20, _n(p.y)) + _pair(30, "0") \
		+ _pair(40, _n(size)) + _pair(1, text) + _pair(50, _n(rot)) + _pair(72, 1) + _pair(73, 2) \
		+ _pair(11, _n(p.x)) + _pair(21, _n(p.y)) + _pair(31, "0")


# ---------------------------------------------------------------------------
# SVG
# ---------------------------------------------------------------------------

static func svg_document(content: Dictionary, units: String = "mm", title: String = "") -> String:
	var k := 1.0 / IN if units == "in" else 1.0
	var w := float(content["w"]) * k
	var h := float(content["h"]) * k
	var stroke := 0.3 * k
	var o := "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
	o += "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%s%s\" height=\"%s%s\" viewBox=\"0 0 %s %s\">\n" % [
		_n(w), units, _n(h), units, _n(w), _n(h)]
	if not title.is_empty():
		o += "  <title>%s</title>\n" % LinkageSvgCutFile.escape_xml(title)
	o += _svg_group("SHEET", [FlatpackProfile.rect_ring(float(content["w"]), float(content["h"]))], h, k, stroke,
		" stroke-dasharray=\"%s %s\"" % [_n(8.0 * k), _n(4.0 * k)])
	o += _svg_group("OUTSIDE_CUT", content["outside"], h, k, stroke, "")
	o += _svg_group("INSIDE_CUT", content["inside"], h, k, stroke, "")
	var folds: Array = content.get("fold", [])
	if not folds.is_empty():
		o += "  <g id=\"FOLD\" fill=\"none\" stroke=\"%s\" stroke-width=\"%s\" stroke-dasharray=\"%s %s\">\n" % [
			SVG_COLORS["FOLD"], _n(stroke), _n(4.0 * k), _n(2.0 * k)]
		for f in folds:
			var a: Vector2 = (f["a"] as Vector2) * k
			var b: Vector2 = (f["b"] as Vector2) * k
			o += "    <line x1=\"%s\" y1=\"%s\" x2=\"%s\" y2=\"%s\"/>\n" % [_n(a.x), _n(h - a.y), _n(b.x), _n(h - b.y)]
		o += "  </g>\n"
		o += "  <g id=\"FOLD_TEXT\" fill=\"%s\" font-family=\"Helvetica, Arial, sans-serif\" text-anchor=\"middle\" dominant-baseline=\"middle\">\n" % SVG_COLORS["FOLD"]
		for f in folds:
			var a: Vector2 = (f["a"] as Vector2) * k
			var b: Vector2 = (f["b"] as Vector2) * k
			var mid := (a + b) * 0.5
			var rot := -rad_to_deg(atan2(b.y - a.y, b.x - a.x))
			if rot > 90.0 or rot < -90.0:
				rot += 180.0
			o += "    <text x=\"%s\" y=\"%s\" font-size=\"%s\" transform=\"rotate(%s %s %s)\">%s</text>\n" % [
				_n(mid.x), _n(h - mid.y), _n(4.0 * k), _n(rot), _n(mid.x), _n(h - mid.y),
				LinkageSvgCutFile.escape_xml(str(f.get("text", "")))]
		o += "  </g>\n"
	var etch: Array = content.get("etch", [])
	if not etch.is_empty():
		o += "  <g id=\"ETCH\" fill=\"none\" stroke=\"%s\" stroke-width=\"%s\">\n" % [SVG_COLORS["ETCH"], _n(stroke)]
		for e in etch:
			var a: Vector2 = (e["a"] as Vector2) * k
			var b: Vector2 = (e["b"] as Vector2) * k
			o += "    <line x1=\"%s\" y1=\"%s\" x2=\"%s\" y2=\"%s\"/>\n" % [_n(a.x), _n(h - a.y), _n(b.x), _n(h - b.y)]
		o += "  </g>\n"
	var labels: Array = content.get("labels", [])
	if not labels.is_empty():
		o += "  <g id=\"ETCH_LABELS\" fill=\"%s\" font-family=\"Helvetica, Arial, sans-serif\" text-anchor=\"middle\" dominant-baseline=\"middle\">\n" % SVG_COLORS["ETCH_LABELS"]
		for lb in labels:
			var p: Vector2 = (lb["p"] as Vector2) * k
			var rot := ""
			if absf(float(lb.get("rot", 0.0))) > 0.01:
				rot = " transform=\"rotate(%s %s %s)\"" % [_n(-float(lb["rot"])), _n(p.x), _n(h - p.y)]
			o += "    <text x=\"%s\" y=\"%s\" font-size=\"%s\"%s>%s</text>\n" % [_n(p.x), _n(h - p.y),
				_n(float(lb["size"]) * k), rot, LinkageSvgCutFile.escape_xml(str(lb["text"]))]
		o += "  </g>\n"
	o += "</svg>\n"
	return o


static func _svg_group(id: String, rings: Array, h: float, k: float, stroke: float, extra: String) -> String:
	var o := "  <g id=\"%s\" fill=\"none\" stroke=\"%s\" stroke-width=\"%s\"%s>\n" % [id, SVG_COLORS[id],
		_n(stroke), extra]
	for r in rings:
		o += "    <path d=\"%s\"/>\n" % FlatpackCam.svg_path(r, h, k)
	o += "  </g>\n"
	return o


# ---------------------------------------------------------------------------
# Writer
# ---------------------------------------------------------------------------

static func safe_name(s: String) -> String:
	return FlatpackCam.safe_name(s)


static func write_all(d: Dictionary, dir: String) -> Dictionary:
	var s: Dictionary = d["spec"]
	var units := str(s["fabrication"]["units"])
	var err := DirAccess.make_dir_recursive_absolute(dir)
	if err != OK and not DirAccess.dir_exists_absolute(dir):
		return {"ok": false, "files": [], "error": "could not create %s" % dir}
	var files: Array = []
	var base := safe_name(str(d["name"]))
	var pn: Dictionary = d["panels"]
	for sh in pn.get("nest", {}).get("sheets", []):
		var idx := int(sh["index"])
		var c := sheet_content(d, idx)
		var stem := "%s_sheet_%02d" % [base, idx + 1]
		for pair in [[".dxf", dxf_document(c, units)], [".svg", svg_document(c, units, "%s — sheet %d" % [str(d["name"]), idx + 1])]]:
			var path := dir.path_join(stem + str(pair[0]))
			if not _write(path, str(pair[1])):
				return {"ok": false, "files": files, "error": "could not write %s" % path}
			files.append(path)
	var sys := str(s["system"])
	if sys == "hub" and str(s["hub"]["kind"]) == "plate":
		for t in d["hub_types"]:
			var c := hub_template(d, t)
			for pair in [[".dxf", dxf_document(c, units)], [".svg", svg_document(c, units, "Hub %s" % str(t["label"]))]]:
				var path := dir.path_join("%s_hub_%s%s" % [base, str(t["label"]), str(pair[0])])
				if not _write(path, str(pair[1])):
					return {"ok": false, "files": files, "error": "could not write %s" % path}
				files.append(path)
	if sys == "bolt_stack":
		for c in d["strut_classes"]:
			var content := strut_end_template(d, c)
			var path := dir.path_join("%s_strut_%s.svg" % [base, str(c["label"])])
			if not _write(path, svg_document(content, units, "Strut %s end" % str(c["label"]))):
				return {"ok": false, "files": files, "error": "could not write %s" % path}
			files.append(path)
	for pair in [["_struts.csv", DomeLabBom.struts_csv(d)], ["_bom.csv", DomeLabBom.bom_csv(d)],
			["_cut_sheet.txt", DomeLabBom.cut_sheet_text(d)],
			["_design.json", JSON.stringify(DomeLabBom.fabrication_json(d), "\t")]]:
		var path := dir.path_join(base + str(pair[0]))
		if not _write(path, str(pair[1])):
			return {"ok": false, "files": files, "error": "could not write %s" % path}
		files.append(path)
	return {"ok": true, "files": files, "error": ""}


static func _write(path: String, text: String) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(text)
	f.close()
	return true
