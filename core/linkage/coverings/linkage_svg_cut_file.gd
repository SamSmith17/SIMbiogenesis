class_name LinkageSvgCutFile
extends RefCounted
## SVG cut files and cut diagrams (port of `js/core/svg-cut-file.js`, A4).
##
## One SVG user unit = one inch; documents carry width / height in inches so
## they print full scale. Geometry comes in y-up (sheet bottom edge on the x
## axis); every drawing flips it into SVG's y-down frame locally. Pure string
## builders — the Build Guide writes the files.

const STYLE := """
  .stock { fill: none; stroke: #8a8a8a; stroke-width: 0.06; stroke-dasharray: 0.6 0.4; }
  .piece { fill: #e9d8b4; fill-opacity: 0.85; stroke: #4a3a22; stroke-width: 0.08; stroke-linejoin: round; }
  .fabric-cut { fill: #dff2ec; fill-opacity: 0.8; stroke: #1f6f5f; stroke-width: 0.08; stroke-linejoin: round; }
  .fabric-fin { fill: none; stroke: #1f6f5f; stroke-width: 0.05; stroke-dasharray: 0.5 0.35; }
  .seam { stroke: #c0392b; stroke-width: 0.12; stroke-dasharray: 0.8 0.3; }
  .cut { stroke: #c0392b; stroke-width: 0.12; }
  .mark { stroke: #c0392b; stroke-width: 0.06; }
  .grommet { fill: #fff; stroke: #1f6f5f; stroke-width: 0.06; }
  .dim { stroke: #2c3e50; stroke-width: 0.05; }
  .outline { fill: #f3e6c8; stroke: #4a3a22; stroke-width: 0.1; stroke-linejoin: round; }
  .grid { fill: none; stroke: #7f8c8d; stroke-width: 0.06; stroke-dasharray: 0.8 0.5; }
  text { font-family: Helvetica, Arial, sans-serif; fill: #2c3e50; }
  .muted { fill: #7f8c8d; }
  .accent { fill: #c0392b; font-weight: 700; }
  .title { font-weight: 700; }
"""


static func _r(v: float, places: int = 3) -> String:
	var s := String.num(LinkageSheetNesting.rnd(v, places), places)
	if s.contains("."):
		s = s.rstrip("0").rstrip(".")
	return "0" if s == "-0" else s


static func escape_xml(s) -> String:
	return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;") \
		.replace("\"", "&quot;").replace("'", "&apos;")


static func _fmt_in(v: float) -> String:
	return LinkageCoveringPlan.fmt_in(v, 16)


static func _fmt_deg(v: float) -> String:
	return "%.1f°" % v


static func _text(x: float, y: float, s: String, o: Dictionary = {}) -> String:
	var size := float(o.get("size", 1.0))
	var anchor := str(o.get("anchor", "start"))
	var cls := " class=\"%s\"" % str(o["cls"]) if o.has("cls") else ""
	var rot := " transform=\"rotate(%s %s %s)\"" % [_r(float(o["rotate"]), 2), _r(x), _r(y)] if o.has("rotate") and float(o["rotate"]) != 0.0 else ""
	return "<text x=\"%s\" y=\"%s\" font-size=\"%s\" text-anchor=\"%s\"%s%s>%s</text>" % [
		_r(x), _r(y), _r(size), anchor, cls, rot, escape_xml(s)]


static func _path(pts: Array, fy: Callable, dx: float = 0.0, cls: String = "piece") -> String:
	if pts.size() < 2:
		return ""
	var parts: PackedStringArray = []
	for i in pts.size():
		var p: Vector2 = pts[i]
		parts.append("%s%s %s" % ["L" if i > 0 else "M", _r(p.x + dx), _r(float(fy.call(p.y)))])
	return "<path class=\"%s\" d=\"%s Z\"/>" % [cls, " ".join(parts)]


## An SVG document sized in inches (`svgDocument`).
static func document(width_in: float, height_in: float, body: String, title: String = "", description: String = "") -> String:
	var w := _r(maxf(1.0, width_in))
	var h := _r(maxf(1.0, height_in))
	return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" \
		+ "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%sin\" height=\"%sin\" viewBox=\"0 0 %s %s\" data-units=\"inches\">\n" % [w, h, w, h] \
		+ "  <title>%s</title>\n" % escape_xml(title if not title.is_empty() else "LinkageLab cut file") \
		+ ("  <desc>%s</desc>\n" % escape_xml(description) if not description.is_empty() else "") \
		+ "  <style>%s</style>\n" % STYLE \
		+ "  <rect x=\"0\" y=\"0\" width=\"%s\" height=\"%s\" fill=\"#ffffff\"/>\n" % [w, h] \
		+ body + "\n</svg>"


static func _title_block(x: float, y: float, lines: Array, font_in: float) -> String:
	var out := ""
	for i in lines.size():
		out += _text(x, y + (i + 1) * font_in * 1.35, str(lines[i]),
			{"size": font_in * 1.3 if i == 0 else font_in, "cls": "title" if i == 0 else "muted"})
	return out


## Full-scale cut file for one nested polygon (`buildSheetCutSvg`): every
## stock sheet with its piece, cut lines, angles and edge marks.
static func sheet_cut_svg(nest: Dictionary, opts: Dictionary = {}) -> String:
	var font_in := float(opts.get("font_in", 1.1))
	var margin := maxf(6.0, font_in * 6.0)
	var gap := font_in * 5.0
	var cw := float(nest["cell_w"])
	var ch := float(nest["cell_h"])
	var lines: Array = opts.get("lines", [])
	var header_h := font_in * 1.35 * (lines.size() + 1) + font_in * 2.0
	var pieces: Array = nest.get("pieces", [])
	var total_h := margin + header_h + pieces.size() * (ch + gap) + margin
	var total_w := margin * 2.0 + maxf(cw, 40.0)
	var body := _title_block(margin, 1.0, [str(opts.get("title", "Sheet cuts"))] + lines, font_in)
	var y0 := 1.0 + header_h + font_in * 2.5
	for piece in pieces:
		var top := y0
		var fy := func(y: float) -> float: return top + ch - y
		body += "<rect class=\"stock\" x=\"%s\" y=\"%s\" width=\"%s\" height=\"%s\"/>" % [_r(margin), _r(top), _r(cw), _r(ch)]
		body += _text(margin, top - font_in * 2.2, "%s — %s %s × %s sheet%s" % [str(piece["piece_id"]), str(nest["orientation"]),
			_fmt_in(cw), _fmt_in(ch), " (full sheet, no cuts)" if bool(piece["is_full_sheet"]) else ""], {"size": font_in, "cls": "title"})
		body += _path(piece["polygon_2d"], fy, margin, "piece")
		for e in piece["edges"]:
			if bool(e["is_stock"]):
				continue
			var ax := (e["from"] as Vector2).x + margin
			var ay: float = fy.call((e["from"] as Vector2).y)
			var bx := (e["to"] as Vector2).x + margin
			var by: float = fy.call((e["to"] as Vector2).y)
			body += "<line class=\"cut\" x1=\"%s\" y1=\"%s\" x2=\"%s\" y2=\"%s\"/>" % [_r(ax), _r(ay), _r(bx), _r(by)]
			var ang := rad_to_deg(atan2(by - ay, bx - ax))
			if ang > 90.0 or ang < -90.0:
				ang += 180.0
			body += _text((ax + bx) / 2.0, (ay + by) / 2.0 - 0.35, "%s @ %s" % [_fmt_in(float(e["length_in"])), _fmt_deg(float(e["angle_deg"]))],
				{"size": font_in * 0.95, "anchor": "middle", "cls": "accent", "rotate": ang})
		for m in piece["marks"]:
			var px := float(m["x"]) + margin
			var py: float = fy.call(float(m["y"]))
			var horiz := str(m["side"]) == "bottom" or str(m["side"]) == "top"
			var tick := 0.8
			if horiz:
				body += "<line class=\"mark\" x1=\"%s\" y1=\"%s\" x2=\"%s\" y2=\"%s\"/>" % [_r(px), _r(py - tick), _r(px), _r(py + tick)]
			else:
				body += "<line class=\"mark\" x1=\"%s\" y1=\"%s\" x2=\"%s\" y2=\"%s\"/>" % [_r(px - tick), _r(py), _r(px + tick), _r(py)]
			var label := "%s from %s" % [_fmt_in(float(m["dist_in"])), str(m["from_corner"])]
			match str(m["side"]):
				"bottom":
					body += _text(px, py + tick + font_in, label, {"size": font_in * 0.9, "anchor": "middle"})
				"top":
					body += _text(px, py - tick - 0.3, label, {"size": font_in * 0.9, "anchor": "middle"})
				"left":
					body += _text(px - tick - 0.3, py + font_in * 0.35, label, {"size": font_in * 0.9, "anchor": "end"})
				_:
					body += _text(px + tick + 0.3, py + font_in * 0.35, label, {"size": font_in * 0.9})
		# Interior angles at the vertices of cut edges.
		var poly: Array = piece["polygon_2d"]
		for i in poly.size():
			var p: Vector2 = poly[i]
			var prev: Vector2 = poly[(i + poly.size() - 1) % poly.size()]
			var nxt: Vector2 = poly[(i + 1) % poly.size()]
			var e_in = null
			var e_out = null
			for e in piece["edges"]:
				if (e["to"] as Vector2) == p and e_in == null:
					e_in = e
				if (e["from"] as Vector2) == p and e_out == null:
					e_out = e
			if e_in == null or e_out == null or (bool(e_in["is_stock"]) and bool(e_out["is_stock"])):
				continue
			var a1 := atan2(prev.y - p.y, prev.x - p.x)
			var a2 := atan2(nxt.y - p.y, nxt.x - p.x)
			var inner := rad_to_deg(absf(a1 - a2))
			if inner > 180.0:
				inner = 360.0 - inner
			var bis := (a1 + a2) / 2.0 + (PI if absf(a1 - a2) > PI else 0.0)
			var lx := p.x + cos(bis) * 3.0 + margin
			var ly: float = fy.call(p.y + sin(bis) * 3.0)
			body += _text(lx, ly + font_in * 0.35, _fmt_deg(inner), {"size": font_in * 0.9, "anchor": "middle", "cls": "muted"})
		y0 += ch + gap
	return document(total_w, total_h, body, str(opts.get("title", "")), " · ".join(PackedStringArray(lines)))


## A fabric pattern (`buildFabricPatternSvg`): each panel's cut outline,
## finished outline, seams and grommets.
static func fabric_pattern_svg(pattern: Dictionary, opts: Dictionary = {}) -> String:
	var font_in := float(opts.get("font_in", 1.1))
	var margin := 2.0
	var gap := 3.0
	var panels: Array = pattern.get("panels", [])
	var lines: Array = opts.get("lines", [])
	var header_h := font_in * 1.35 * (lines.size() + 1) + 2.0
	var sum_w := 0.0
	var max_h := 0.0
	for pn in panels:
		sum_w += float(pn["bbox_w"])
		max_h = maxf(max_h, float(pn["bbox_h"]))
	var total_w := margin * 2.0 + maxf(40.0, sum_w + gap * maxi(0, panels.size() - 1))
	var total_h := margin + header_h + max_h + font_in * 4.0 + margin
	var body := _title_block(margin, margin, [str(opts.get("title", "Fabric pattern"))] + lines, font_in)
	var x0 := margin
	var top := margin + header_h
	for pn in panels:
		var bh := float(pn["bbox_h"])
		var fy := func(y: float) -> float: return top + bh - y
		body += _path(pn["cut_2d"], fy, x0, "fabric-cut")
		body += _path(pn["finished_2d"], fy, x0, "fabric-fin")
		var fin: Array = pn["finished_2d"]
		for e in pn["seam_edges"]:
			var a: Vector2 = fin[int(e)]
			var b: Vector2 = fin[(int(e) + 1) % fin.size()]
			body += "<line class=\"seam\" x1=\"%s\" y1=\"%s\" x2=\"%s\" y2=\"%s\"/>" % [_r(a.x + x0), _r(float(fy.call(a.y))), _r(b.x + x0), _r(float(fy.call(b.y)))]
		for g in pn["grommets"]:
			body += "<circle class=\"grommet\" cx=\"%s\" cy=\"%s\" r=\"0.3\"/>" % [_r((g as Vector2).x + x0), _r(float(fy.call((g as Vector2).y)))]
		body += _text(x0, top - 0.3, "%s: cut %s × %s" % [str(pn["label"]), _fmt_in(float(pn["bbox_w"])), _fmt_in(bh)], {"size": font_in, "cls": "title"})
		var cut: Array = pn["cut_2d"]
		for i in cut.size():
			var p: Vector2 = cut[i]
			var q: Vector2 = cut[(i + 1) % cut.size()]
			var ang := rad_to_deg(atan2(float(fy.call(q.y)) - float(fy.call(p.y)), q.x - p.x))
			if ang > 90.0 or ang < -90.0:
				ang += 180.0
			body += _text((p.x + q.x) / 2.0 + x0, float(fy.call((p.y + q.y) / 2.0)) - 0.3, _fmt_in(p.distance_to(q)),
				{"size": font_in * 0.85, "anchor": "middle", "cls": "muted", "rotate": ang})
		x0 += float(pn["bbox_w"]) + gap
	var legend_y := top + max_h + font_in * 1.6
	body += _text(margin, legend_y, "Solid = cut line (hem %s, seam %s). Dashed = finished edge after %s%% tension shrink. Red dashed = seam. Circles = grommets every %s." % [
		_fmt_in(float(pattern.get("hem_in", 0.0))), _fmt_in(float(pattern.get("seam_in", 0.0))), str(pattern.get("stretch_pct", 0.0)),
		_fmt_in(float(pattern.get("grommet_spacing_in", 12.0)))], {"size": font_in * 0.9, "cls": "muted"})
	body += _text(margin, legend_y + font_in * 1.35, "%d panel%s on %s roll · %s yd · %d grommets" % [int(pattern["panel_count"]),
		"" if int(pattern["panel_count"]) == 1 else "s", _fmt_in(float(pattern["roll_width_in"])), str(pattern["fabric_yards"]),
		int(pattern["grommet_count"])], {"size": font_in * 0.9, "cls": "muted"})
	return document(total_w, total_h, body, str(opts.get("title", "")), " · ".join(PackedStringArray(lines)))


## Plan view of the roof with the radial tarps over it (`buildShadeLayoutSvg`).
static func shade_layout_svg(shade: Dictionary, opts: Dictionary = {}) -> String:
	var verts: Array = (shade.get("polygon", {}) as Dictionary).get("vertices", [])
	var cloths: Array = shade.get("shapes", [])
	if verts.size() < 3:
		return document(10.0, 4.0, _text(1.0, 2.0, "no roof", {"size": 1.0}))
	var poly: Array = []
	for v in verts:
		poly.append(Vector2((v as Vector3).x, -(v as Vector3).z))
	var quads: Array = []
	var all_pts: Array = poly.duplicate()
	for c in cloths:
		var q: Array = []
		for p in c.get("plan_2d", []):
			q.append(Vector2((p as Vector2).x, -(p as Vector2).y))
		quads.append(q)
		all_pts.append_array(q)
	var bb := LinkageSheetNesting.bbox(all_pts)
	var w := float(bb["w"])
	var h := float(bb["h"])
	var font_in := float(opts.get("font_in", maxf(3.0, w * 0.025)))
	var pad := font_in * 3.0
	var ox := pad - float(bb["min_x"])
	var oy := pad
	var min_y := float(bb["min_y"])
	var fy := func(y: float) -> float: return oy + h - (y - min_y)
	var fill := str(shade.get("color", "#6f8f86"))
	var body := ""
	for i in quads.size():
		var q2: Array = quads[i]
		if q2.size() < 3:
			continue
		body += _path(q2, fy, ox, "fabric-cut").replace("class=\"fabric-cut\"",
			"class=\"fabric-cut\" fill=\"%s\" fill-opacity=\"0.3\" stroke=\"%s\" stroke-width=\"0.4\"" % [fill, fill])
		var cen := Vector2.ZERO
		for p in q2:
			cen += p
		cen /= q2.size()
		body += _text(cen.x + ox, float(fy.call(cen.y)) + font_in * 0.35, str(int(cloths[i].get("span_index", i)) + 1),
			{"size": font_in * 1.2, "anchor": "middle", "cls": "muted"})
	body += _path(poly, fy, ox, "grid").replace("class=\"grid\"", "class=\"grid\" stroke=\"#4a3a22\" stroke-width=\"0.25\" stroke-dasharray=\"none\"")
	var sizes: PackedStringArray = []
	for sz in shade.get("sizes", []):
		sizes.append("%d × %s × %s" % [int(sz["qty"]), _fmt_in(float(sz["width_in"])), _fmt_in(float(sz["length_in"]))])
	body += _text(pad, pad - font_in * 0.8, "%d tarps (%s), array rotated %s°, %s%% covered" % [cloths.size(), ", ".join(sizes),
		str(shade.get("rotation_deg", 0.0)), str(shade.get("coverage_pct", 0.0))], {"size": font_in, "cls": "title"})
	return document(w + pad * 2.0, h + pad * 2.0, body, "Roof shade tarps")
