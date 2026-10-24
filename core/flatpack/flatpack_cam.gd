class_name FlatpackCam
extends RefCounted

## CNC files for a solved flat-pack design: one DXF and one SVG per sheet, a
## fit-test coupon, and a plain-text cut list. Pure string builders plus one
## writer; nothing here touches the scene.
##
## DXF: ASCII R12 (AC1009), the version every CAM program reads (VCarve,
## Fusion, Easel, LightBurn, Inkscape). Outlines are closed POLYLINEs whose
## vertices carry the bulge (group 42), so fillets, dogbones and arches stay
## true arcs. Layers:
##   OUTSIDE_CUT  part outlines (cut on the outside of the line)
##   INSIDE_CUT   mortises and wedge holes (cut on the inside)
##   ETCH_LABELS  part labels (engrave or skip)
##   SHEET        the sheet's edge, for reference (never cut)
## Units are inches or millimetres ($INSUNITS 1 / 4); the drawing is at 1:1.
##
## SVG: the same layers as <g> groups, width/height in "in" or "mm" so a laser
## or CAM import lands at scale; y is flipped into SVG's y-down frame and each
## arc becomes an `A` command. No filled shapes and no background rectangle:
## an importer turns every path into a toolpath.

const LAYERS := {
	"OUTSIDE_CUT": 1,    # red
	"INSIDE_CUT": 5,     # blue
	"ETCH_LABELS": 3,    # green
	"SHEET": 8,          # grey
}
const SVG_COLORS := {"OUTSIDE_CUT": "#d0021b", "INSIDE_CUT": "#1a5fd0",
	"ETCH_LABELS": "#1e8a3a", "SHEET": "#9a9a9a"}
const MM := 25.4

## Fit-test coupon: slots from the measured thickness down/up in these steps.
const COUPON_STEPS := [-0.01, -0.005, 0.0, 0.005, 0.01, 0.015, 0.02]
const COUPON_SLOT_DEPTH := 1.25
const COUPON_PITCH := 1.6


# ---------------------------------------------------------------------------
# Sheet geometry
# ---------------------------------------------------------------------------

## Everything on one sheet, in sheet inches (y-up, origin lower-left):
## {w, h, outside: [ring], inside: [ring], labels: [{p, text, size, rot}]}.
static func sheet_content(design: Dictionary, sheet_index: int) -> Dictionary:
	var nest: Dictionary = design.get("nest", {})
	var out := {"w": float(nest.get("sheet_w", 48.0)), "h": float(nest.get("sheet_h", 96.0)),
		"outside": [], "inside": [], "labels": []}
	for sh in nest.get("sheets", []):
		if int(sh["index"]) != sheet_index:
			continue
		for pl in sh["placements"]:
			var p := FlatpackDesign.part(design, str(pl["id"]))
			if p.is_empty():
				continue
			var bb: Rect2 = p["bbox"]
			(out["outside"] as Array).append(FlatpackNesting.ring_on_sheet(p["ring"], bb, pl))
			for h in p.get("hole_rings", []):
				(out["inside"] as Array).append(FlatpackNesting.ring_on_sheet(h, bb, pl))
			var lp := _label_point(p, bb)
			var size := clampf(minf(bb.size.x, bb.size.y) * 0.25, 0.4, 1.25)
			(out["labels"] as Array).append({
				"p": FlatpackNesting.point_on_sheet(lp, bb, pl), "size": size,
				"text": str(p.get("label", p["id"])),
				"rot": 90.0 if (bool(pl.get("rot", false)) != (bb.size.y > bb.size.x * 1.6)) else 0.0})
	return out


## A spot inside the part for its label: the bounding-box centre, or the
## nearest solid point to it on a coarse grid.
static func _label_point(p: Dictionary, bb: Rect2) -> Vector2:
	var outer := FlatpackProfile.tessellate(p["ring"], 1.0)
	var holes: Array = []
	for h in p.get("hole_rings", []):
		holes.append(FlatpackProfile.tessellate(h, 1.0))
	var c := bb.get_center()
	if _solid(c, outer, holes):
		return c
	var best := c
	var best_d := INF
	var step := maxf(minf(bb.size.x, bb.size.y) / 8.0, 0.25)
	var y := bb.position.y + step * 0.5
	while y < bb.end.y:
		var x := bb.position.x + step * 0.5
		while x < bb.end.x:
			var q := Vector2(x, y)
			if _solid(q, outer, holes) and q.distance_to(c) < best_d:
				best_d = q.distance_to(c)
				best = q
			x += step
		y += step
	return best


static func _solid(q: Vector2, outer: PackedVector2Array, holes: Array) -> bool:
	if not Geometry2D.is_point_in_polygon(q, outer):
		return false
	for h in holes:
		if Geometry2D.is_point_in_polygon(q, h):
			return false
	return true


# ---------------------------------------------------------------------------
# DXF
# ---------------------------------------------------------------------------

static func _n(v: float) -> String:
	var s := "%.4f" % v
	if s.contains("."):
		s = s.rstrip("0").rstrip(".")
	return "0" if s == "-0" else s


static func _pair(code: int, value) -> String:
	return "%d\n%s\n" % [code, str(value)]


static func dxf_document(content: Dictionary, units: String = "in", labels: bool = true) -> String:
	var k := MM if units == "mm" else 1.0
	var w := float(content["w"]) * k
	var h := float(content["h"]) * k
	var o := ""
	o += _pair(0, "SECTION") + _pair(2, "HEADER")
	o += _pair(9, "$ACADVER") + _pair(1, "AC1009")
	o += _pair(9, "$INSUNITS") + _pair(70, 4 if units == "mm" else 1)
	o += _pair(9, "$MEASUREMENT") + _pair(70, 1 if units == "mm" else 0)
	o += _pair(9, "$EXTMIN") + _pair(10, "0") + _pair(20, "0") + _pair(30, "0")
	o += _pair(9, "$EXTMAX") + _pair(10, _n(w)) + _pair(20, _n(h)) + _pair(30, "0")
	o += _pair(0, "ENDSEC")
	o += _pair(0, "SECTION") + _pair(2, "TABLES")
	o += _pair(0, "TABLE") + _pair(2, "LTYPE") + _pair(70, 1)
	o += _pair(0, "LTYPE") + _pair(2, "CONTINUOUS") + _pair(70, 0) + _pair(3, "Solid line") \
		+ _pair(72, 65) + _pair(73, 0) + _pair(40, "0.0")
	o += _pair(0, "ENDTAB")
	o += _pair(0, "TABLE") + _pair(2, "LAYER") + _pair(70, LAYERS.size())
	for name in LAYERS:
		o += _pair(0, "LAYER") + _pair(2, name) + _pair(70, 0) + _pair(62, LAYERS[name]) \
			+ _pair(6, "CONTINUOUS")
	o += _pair(0, "ENDTAB") + _pair(0, "ENDSEC")
	o += _pair(0, "SECTION") + _pair(2, "ENTITIES")
	o += _dxf_poly(FlatpackProfile.rect_ring(float(content["w"]), float(content["h"])), "SHEET", k)
	for r in content["outside"]:
		o += _dxf_poly(r, "OUTSIDE_CUT", k)
	for r in content["inside"]:
		o += _dxf_poly(r, "INSIDE_CUT", k)
	if labels:
		for lb in content["labels"]:
			var p: Vector2 = (lb["p"] as Vector2) * k
			o += _pair(0, "TEXT") + _pair(8, "ETCH_LABELS") + _pair(10, _n(p.x)) + _pair(20, _n(p.y)) \
				+ _pair(30, "0") + _pair(40, _n(float(lb["size"]) * k)) + _pair(1, str(lb["text"])) \
				+ _pair(50, _n(float(lb["rot"]))) + _pair(72, 1) + _pair(73, 2) \
				+ _pair(11, _n(p.x)) + _pair(21, _n(p.y)) + _pair(31, "0")
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
		if absf(bul[i]) > 1e-9:
			o += _pair(42, "%.6f" % bul[i])
	o += _pair(0, "SEQEND") + _pair(8, layer)
	return o


## A minimal reader for what dxf_document writes (the selftest's round trip):
## {polylines: {layer: count}, vertices, texts, min: Vector2, max: Vector2,
## bulged}.
static func dxf_parse(text: String) -> Dictionary:
	var lines := text.split("\n")
	var out := {"polylines": {}, "vertices": 0, "texts": 0, "bulged": 0,
		"min": Vector2(INF, INF), "max": Vector2(-INF, -INF), "units": -1}
	var i := 0
	var entity := ""
	var layer := ""
	var x := NAN
	var in_entities := false
	var last_var := ""
	while i + 1 < lines.size():
		var code := int(lines[i].strip_edges())
		var val := lines[i + 1].strip_edges()
		i += 2
		if code == 9:
			last_var = val
		if code == 70 and last_var == "$INSUNITS" and out["units"] == -1:
			out["units"] = int(val)
		if code == 2 and val == "ENTITIES":
			in_entities = true
		if not in_entities:
			continue
		if code == 0:
			entity = val
			if val == "POLYLINE" or val == "TEXT":
				layer = ""
			continue
		if code == 8:
			layer = val
			if entity == "POLYLINE":
				var d: Dictionary = out["polylines"]
				d[layer] = int(d.get(layer, 0)) + 1
			elif entity == "TEXT":
				out["texts"] = int(out["texts"]) + 1
		if entity == "VERTEX":
			if code == 10:
				x = float(val)
			elif code == 20:
				var y := float(val)
				out["vertices"] = int(out["vertices"]) + 1
				out["min"] = Vector2(minf(out["min"].x, x), minf(out["min"].y, y))
				out["max"] = Vector2(maxf(out["max"].x, x), maxf(out["max"].y, y))
			elif code == 42:
				out["bulged"] = int(out["bulged"]) + 1
	return out


# ---------------------------------------------------------------------------
# SVG
# ---------------------------------------------------------------------------

static func svg_document(content: Dictionary, units: String = "in", labels: bool = true,
		title: String = "") -> String:
	var k := MM if units == "mm" else 1.0
	var w := float(content["w"]) * k
	var h := float(content["h"]) * k
	var stroke := 0.02 * k
	var o := "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
	o += "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%s%s\" height=\"%s%s\" viewBox=\"0 0 %s %s\">\n" % [
		_n(w), units, _n(h), units, _n(w), _n(h)]
	if not title.is_empty():
		o += "  <title>%s</title>\n" % LinkageSvgCutFile.escape_xml(title)
	o += _svg_group("SHEET", [FlatpackProfile.rect_ring(float(content["w"]), float(content["h"]))],
		h, k, stroke, " stroke-dasharray=\"%s %s\"" % [_n(0.5 * k), _n(0.3 * k)])
	o += _svg_group("OUTSIDE_CUT", content["outside"], h, k, stroke, "")
	o += _svg_group("INSIDE_CUT", content["inside"], h, k, stroke, "")
	if labels:
		o += "  <g id=\"ETCH_LABELS\" fill=\"%s\" font-family=\"Helvetica, Arial, sans-serif\" text-anchor=\"middle\" dominant-baseline=\"middle\">\n" % SVG_COLORS["ETCH_LABELS"]
		for lb in content["labels"]:
			var p: Vector2 = (lb["p"] as Vector2) * k
			var rot := ""
			if absf(float(lb["rot"])) > 0.01:
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
		o += "    <path d=\"%s\"/>\n" % svg_path(r, h, k)
	o += "  </g>\n"
	return o


## One closed ring as SVG path data, y flipped into the y-down frame.
static func svg_path(ring: Dictionary, h: float, k: float) -> String:
	var pts: PackedVector2Array = ring["pts"]
	var bul: PackedFloat64Array = ring["bulge"]
	var n := pts.size()
	if n == 0:
		return ""
	var parts: PackedStringArray = []
	parts.append("M%s %s" % [_n(pts[0].x * k), _n(h - pts[0].y * k)])
	for i in n:
		var a := pts[i]
		var b := pts[(i + 1) % n]
		var bb := bul[i]
		if absf(bb) < 1e-9:
			if i < n - 1:
				parts.append("L%s %s" % [_n(b.x * k), _n(h - b.y * k)])
			continue
		var sweep := 4.0 * atan(bb)
		var r := FlatpackProfile.arc_center(a, b, bb).distance_to(a) * k
		var large := 1 if absf(sweep) > PI else 0
		# A counter-clockwise arc (bulge > 0) in y-up reads counter-clockwise
		# on screen after the flip, which is SVG's sweep-flag 0.
		var sw := 0 if bb > 0.0 else 1
		parts.append("A%s %s 0 %d %d %s %s" % [_n(r), _n(r), large, sw, _n(b.x * k), _n(h - b.y * k)])
	return " ".join(parts) + " Z"


# ---------------------------------------------------------------------------
# Coupon, cut list, writer
# ---------------------------------------------------------------------------

## A fit-test strip: one slot per step round the measured thickness, the
## width engraved beside each (in thousandths). Cut it first and push an
## offcut of the same sheet into each slot.
static func coupon_content(design: Dictionary) -> Dictionary:
	var s: Dictionary = design["spec"]
	var t := float(s["material"]["thickness"])
	var mc: Dictionary = s["machine"]
	var relief := {"relief": str(mc["relief"]), "bit_r": float(mc["bit_d"]) * 0.5 + 0.005}
	var n := COUPON_STEPS.size()
	var w := COUPON_PITCH * (n + 1)
	var hh := 3.0
	var notches: Array = []
	for i in n:
		var width := t + float(COUPON_STEPS[i])
		notches.append(FlatpackProfile.make_notch(2, w - COUPON_PITCH * (i + 1), width,
			COUPON_SLOT_DEPTH))
	var base := FlatpackTemplates.rect(w, hh)
	var r := FlatpackProfile.ring_from_base(base, PackedFloat64Array([0.25, 0.25, 0.25, 0.25]),
		notches, relief)
	var margin := 0.5
	var ring := FlatpackProfile.transform_ring(r["ring"], 0.0, Vector2(margin, margin))
	var labels: Array = []
	for i in n:
		var width := t + float(COUPON_STEPS[i])
		labels.append({"p": Vector2(margin + COUPON_PITCH * (i + 1), margin + 0.9), "size": 0.32,
			"text": "%03d" % int(round(width * 1000.0)), "rot": 0.0})
	return {"w": w + margin * 2.0, "h": hh + margin * 2.0, "outside": [ring], "inside": [],
		"labels": labels}


static func cut_list_text(design: Dictionary) -> String:
	var s: Dictionary = design["spec"]
	var units := str(s["machine"]["units"])
	var bom: Dictionary = design["bom"]
	var lines: PackedStringArray = []
	lines.append(str(design["name"]))
	var nom := str(s["material"]["nominal"])
	if nom.contains("/"):
		nom += "\""
	lines.append("%s · %s plywood (%s actual) · %s" % [
		FlatpackSpec.TYPE_LABELS.get(design["type"], design["type"]),
		nom, FlatpackSpec.fmt_in(float(s["material"]["thickness"])),
		UiText.count(int(bom["sheets"]), "sheet") + " of " + str(FlatpackSpec.SHEET_LABELS.get(
			str(s["material"]["sheet"]), "custom stock"))])
	lines.append("")
	lines.append("Part        Qty  Size                Slots  Holes  Sheet")
	for row in design["cut_list"]:
		lines.append("%-4s %-12s %2d  %-18s %5d  %5d  %s" % [str(row.get("label", "")),
			str(row["name"]).left(12), int(row["qty"]),
			FlatpackSpec.fmt_size(float(row["w"]), float(row["h"]), units), int(row["notches"]),
			int(row["holes"]), ", ".join(PackedStringArray((row["sheets"] as Array).map(func(v): return str(v))))])
	lines.append("")
	lines.append("Cut length %.0f ft in %s · about %d min of router time" % [float(bom["cut_ft"]),
		UiText.count(int(bom["passes"]), "pass", "passes"), int(round(float(bom["cut_min"])))])
	lines.append("Weight about %.0f kg (%.0f lb) · %d%% of the sheets used" % [float(bom["mass_kg"]),
		float(bom["mass_kg"]) / FlatpackSpec.LB_TO_KG, int(round(float(bom["utilization"]) * 100.0))])
	lines.append("Bit %s · slot clearance %.3f\" per side · %s" % [
		FlatpackSpec.fmt_in(float(s["machine"]["bit_d"])), float(s["machine"]["clearance"]),
		FlatpackSpec.RELIEF_LABELS.get(str(s["machine"]["relief"]), "")])
	if not (design["warnings"] as Array).is_empty():
		lines.append("")
		lines.append("Check:")
		for w in design["warnings"]:
			lines.append("  - %s" % str(w))
	return "\n".join(lines) + "\n"


static func safe_name(s: String) -> String:
	var out := ""
	for ch in s.strip_edges():
		if ch.is_valid_identifier() or ch in "0123456789-_":
			out += ch
		elif ch == " ":
			out += "_"
	while out.contains("__"):
		out = out.replace("__", "_")
	out = out.strip_edges().trim_prefix("_").trim_suffix("_")
	return out if not out.is_empty() else "furniture"


## Write every file for the design into `dir` (created). Returns {ok, files,
## error}.
static func write_all(design: Dictionary, dir: String) -> Dictionary:
	var s: Dictionary = design["spec"]
	var units := str(s["machine"]["units"])
	var labels := bool(s["machine"]["labels"])
	var err := DirAccess.make_dir_recursive_absolute(dir)
	if err != OK and not DirAccess.dir_exists_absolute(dir):
		return {"ok": false, "files": [], "error": "could not create %s" % dir}
	var files: Array = []
	var base := safe_name(str(design["name"]))
	for sh in design["nest"]["sheets"]:
		var idx := int(sh["index"])
		var c := sheet_content(design, idx)
		var stem := "%s_sheet_%02d" % [base, idx + 1]
		var title := "%s — sheet %d" % [str(design["name"]), idx + 1]
		for pair in [[".dxf", dxf_document(c, units, labels)], [".svg", svg_document(c, units, labels, title)]]:
			var path := dir.path_join(stem + str(pair[0]))
			if not _write(path, str(pair[1])):
				return {"ok": false, "files": files, "error": "could not write %s" % path}
			files.append(path)
	var cc := coupon_content(design)
	for pair in [[".dxf", dxf_document(cc, units, true)], [".svg", svg_document(cc, units, true, "Fit test")]]:
		var path := dir.path_join("%s_fit_coupon%s" % [base, str(pair[0])])
		if not _write(path, str(pair[1])):
			return {"ok": false, "files": files, "error": "could not write %s" % path}
		files.append(path)
	var lp := dir.path_join("%s_cut_list.txt" % base)
	if not _write(lp, cut_list_text(design)):
		return {"ok": false, "files": files, "error": "could not write %s" % lp}
	files.append(lp)
	return {"ok": true, "files": files, "error": ""}


static func _write(path: String, text: String) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(text)
	f.close()
	return true
