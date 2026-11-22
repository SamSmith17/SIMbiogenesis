class_name CtrlSheet
extends RefCounted

## The terminals of a controller as a flat drawing (Controller Lab Phase 3):
## one face seen straight on, every connector's outline where it sits, every
## pin labelled with what it is for, and a coloured lead from each wired pin
## fanned out below the unit, as a wiring diagram draws it.
##
## `layout(d, face)` is the ONE description both the modal's 2D view and the
## SVG export draw: millimetres in the face's own frame (x right, y UP; the
## renderers flip y). The front face takes the wiring bay's ports too (the
## bay's back plate has the front's axes), with the bay's outline.
##
## Wire colours follow US practice (NEC 200.6 / 250.119 and common DC use):
## L / L1 black, L2 red, N white, G green; DC + red, − black; data teal.

const FACE_ORDER := ["front", "bottom", "left", "right", "top", "back", "bay"]
const FACE_WORDS := {"front": "Front", "back": "Back", "left": "Left side", "right": "Right side",
	"top": "Top", "bottom": "Underside", "bay": "Wiring bay"}
const SHORT := {
	"bat": "BAT", "load": "LOAD", "dcin": "DC IN", "ac_out": "AC OUT", "ac_in": "GRID", "gen": "GEN",
	"comm_bms": "BMS", "rs485": "RS485", "can": "CAN", "ve_direct": "VE.Direct", "ve_bus": "VE.Bus",
	"usb": "USB", "wifi": "WIFI", "temp": "TEMP", "dry": "DRY", "remote": "REMOTE", "rsd": "RSD",
	"ground": "PE", "ui": "",
}
const C_RED := Color(0.86, 0.13, 0.11)
const C_BLACK := Color(0.08, 0.08, 0.09)
const C_WHITE := Color(0.93, 0.93, 0.92)
const C_GREEN := Color(0.12, 0.62, 0.22)
const C_TEAL := Color(0.1, 0.66, 0.72)
const C_GREY := Color(0.58, 0.6, 0.62)


## Faces that carry ports, in drawing order (the bay folds into the front).
static func faces_with_ports(d: Dictionary) -> Array:
	var has := {}
	for p in (d.get("ports", []) as Array):
		var f := str(p["face"])
		has["front" if f == "bay" else f] = true
	var out: Array = []
	for f2 in FACE_ORDER:
		if has.has(f2):
			out.append(f2)
	return out


## "pv2+" → "PV2 +", "ac_out_N" → "AC OUT N", "rs485" → "RS485".
static func short(role: String) -> String:
	if role == "":
		return ""
	var g := CtrlRoles.group_of(role)
	var base := ""
	if g.begins_with("pv"):
		base = g.to_upper()
	else:
		base = str(SHORT.get(g, g.to_upper()))
	var rest := role.substr(g.length()).trim_prefix("_")
	match rest:
		"":
			return base
		"+":
			return base + " +"
		"-":
			return base + " −"
	return (base + " " + rest).strip_edges()


static func wire_color(role: String) -> Color:
	var g := CtrlRoles.group_of(role)
	var rest := role.substr(g.length()).trim_prefix("_")
	if g == "ground" or rest == "G":
		return C_GREEN
	match rest:
		"N":
			return C_WHITE
		"L", "L1":
			return C_BLACK
		"L2":
			return C_RED
		"+":
			return C_RED
		"-":
			return C_BLACK
	if CtrlRoles.DATA_GROUPS.has(g) or CtrlRoles.IO_GROUPS.has(g):
		return C_TEAL
	return C_GREY


## The drawing of one face: {face, size, rect, bay (Rect2 or none), text_mm,
## ports: [{id, label, connector, domain, color, corners, centre, pins}],
## leads: [{port, pin, role, text, color, pts: [Vector2], end}], bounds}.
static func layout(d: Dictionary, face: String) -> Dictionary:
	var faces: Dictionary = d.get("faces", {})
	if not faces.has(face):
		return {}
	var f: Dictionary = faces[face]
	var size: Vector2 = f["size"]
	var c: Vector3 = f["c"]
	var fx: Vector3 = f["x"]
	var fy: Vector3 = f["y"]
	var rect := Rect2(-size * 0.5, size)
	var ts := clampf(maxf(size.x, size.y) / 55.0, 2.5, 9.0)
	var out := {"face": face, "size": size, "rect": rect, "text_mm": ts, "ports": [], "leads": [],
		"has_bay": false, "bay": Rect2()}
	var sources := [face]
	if face == "front" and faces.has("bay"):
		sources.append("bay")
		var fb: Dictionary = faces["bay"]
		var bc: Vector3 = (fb["c"] as Vector3) - c
		var bs: Vector2 = fb["size"]
		out["has_bay"] = true
		out["bay"] = Rect2(Vector2(bc.dot(fx), bc.dot(fy)) - bs * 0.5, bs)
	var role_pins: Array = []
	for p in (d.get("ports", []) as Array):
		var pf := str(p["face"])
		if not sources.has(pf):
			continue
		var off := Vector2.ZERO
		if pf != face:
			var q: Vector3 = ((faces[pf] as Dictionary)["c"] as Vector3) - c
			off = Vector2(q.dot(fx), q.dot(fy))
		var corners: Array = []
		var centre := Vector2.ZERO
		for k in (p["corners"] as Array):
			var v: Vector2 = (k as Vector2) + off
			corners.append(v)
			centre += v
		centre /= maxf(float(corners.size()), 1.0)
		var e: Dictionary = p["entry"]
		var dom := str(e.get("domain", ""))
		var pins: Array = []
		for pin in (p["pins"] as Array):
			var w: Vector3 = (pin["pos"] as Vector3) - c
			var pos := Vector2(w.dot(fx), w.dot(fy))
			var role := str(pin["role"])
			var rec := {"id": str(pin["id"]), "label": str(pin["label"]), "role": role, "pos": pos,
				"text": short(role), "color": wire_color(role)}
			pins.append(rec)
			if role != "" and CtrlRoles.group_of(role) != "ui":
				role_pins.append({"port": str(p["id"]), "pin": rec})
		var lab := str(p["label"]) if str(p["label"]) != "" else str(e.get("label", ""))
		(out["ports"] as Array).append({"id": str(p["id"]), "label": lab, "connector": str(p["connector"]),
			"domain": dom, "color": ConnectorCatalog.DOMAIN_COLORS.get(dom, C_GREY), "corners": corners,
			"centre": centre, "pins": pins, "bay": pf == "bay"})
	out["leads"] = _leads(role_pins, rect, ts)
	out["look"] = _look(d, face, rect)
	var bb := rect
	for l in (out["leads"] as Array):
		for pt in (l["pts"] as Array):
			bb = bb.expand(pt)
		var end: Vector2 = l["end"]
		bb = bb.expand(end + Vector2(0, -ts * 0.62 * float(str(l["text"]).length()) - ts))
	out["bounds"] = bb.grow(ts * 2.0)
	return out


## What the face looks like, so a 2D drawing of it reads as the unit:
## {color, corner_r, split_y (NAN = none), split_color, plate (a front plate
## over a darker shell: {inset, color} or {}), bands [{y0, y1, color,
## x_inset}], panels [{rect, color, r}], texts [{u, v, text, size, color,
## bold, align, max_w}]}, in the face's own mm frame. Bands, panels and
## texts are the front's only.
static func _look(d: Dictionary, face: String, rect: Rect2) -> Dictionary:
	var s: Dictionary = d.get("spec", {})
	var b: Dictionary = s.get("body", {})
	var h := float(d.get("h", rect.size.y))
	var body_col := CtrlSpec.color_of(b.get("color", [0.12, 0.12, 0.13]))
	var out := {"color": body_col, "corner_r": float(b.get("corner_r", 0.0)), "split_y": NAN,
		"split_color": body_col, "plate": {}, "bands": [], "panels": [], "texts": []}
	var sp: Dictionary = b.get("split", {})
	if face == "front" and float(sp.get("y", -1.0)) > 0.0:
		out["split_y"] = float(sp["y"]) - h * 0.5
		out["split_color"] = CtrlSpec.color_of(sp.get("color", [0, 0, 0]), body_col)
	var plate: Dictionary = b.get("plate", {})
	if face == "front" and bool(plate.get("on", false)):
		out["plate"] = {"inset": float(plate.get("inset", 8.0)), "color": CtrlSpec.color_of(plate.get("color", [0.9, 0.9, 0.9]))}
	if face != "front":
		return out
	for bd in (s.get("bands", []) as Array):
		(out["bands"] as Array).append({"y0": float(bd.get("y0", 0.0)) - h * 0.5, "y1": float(bd.get("y1", 0.0)) - h * 0.5,
			"color": CtrlSpec.color_of(bd.get("color", [0.9, 0.4, 0.1])), "x_inset": float(bd.get("x_inset", 0.0))})
	for pn in (s.get("panels", []) as Array):
		var x0 := float(pn.get("x0", -20.0))
		var x1 := float(pn.get("x1", 20.0))
		var ya := float(pn.get("y0", -20.0))
		var yb := float(pn.get("y1", 20.0))
		(out["panels"] as Array).append({"rect": Rect2(x0, ya, x1 - x0, yb - ya),
			"color": CtrlSpec.color_of(pn.get("color", [-1.0, 0, 0]), body_col), "r": float(pn.get("r", 4.0))})
	for t in (s.get("texts", []) as Array):
		if str(t.get("face", "front")) != "front" or absf(float(t.get("rot", 0.0))) > 0.01:
			continue
		(out["texts"] as Array).append({"u": float(t.get("u", 0.0)), "v": float(t.get("v", 0.0)), "text": str(t.get("text", "")),
			"size": float(t.get("size", 6.0)), "color": CtrlSpec.color_of(t.get("color", [0.95, 0.95, 0.95])),
			"bold": bool(t.get("bold", false)), "align": str(t.get("align", "center")), "max_w": float(t.get("max_w", 0.0))})
	return out


## Leads drop from each pin to below the face, fan out to slots at least a
## label apart (pins on a 5 mm strip are closer than their labels), then down.
static func _leads(role_pins: Array, rect: Rect2, ts: float) -> Array:
	role_pins.sort_custom(func(a, b) -> bool:
		var pa: Vector2 = a["pin"]["pos"]
		var pb: Vector2 = b["pin"]["pos"]
		return pa.x < pb.x if absf(pa.x - pb.x) > 0.01 else pa.y > pb.y)
	var n := role_pins.size()
	var gap := ts * 1.45
	var slots: Array = []
	for rp in role_pins:
		slots.append(((rp["pin"] as Dictionary)["pos"] as Vector2).x)
	# Every neighbour at least a gap apart, as close to its pin as it can be:
	# the mean of the tightest packing pushed right and pushed left (both keep
	# the gap, so their mean does too).
	if n > 1:
		var fw: Array = slots.duplicate()
		for i in range(1, n):
			fw[i] = maxf(float(fw[i]), float(fw[i - 1]) + gap)
		var bw: Array = slots.duplicate()
		for i in range(n - 2, -1, -1):
			bw[i] = minf(float(bw[i]), float(bw[i + 1]) - gap)
		for i in n:
			slots[i] = (float(fw[i]) + float(bw[i])) * 0.5
	var y_drop := rect.position.y - ts * 2.0
	var y_fan := y_drop - ts * 2.5
	var y_end := y_fan - ts * 2.0
	var out: Array = []
	for i in n:
		var pin: Dictionary = role_pins[i]["pin"]
		var p0: Vector2 = pin["pos"]
		var sx := float(slots[i])
		out.append({"port": role_pins[i]["port"], "pin": pin["id"], "role": pin["role"], "text": pin["text"],
			"color": pin["color"], "pts": [p0, Vector2(p0.x, y_drop), Vector2(sx, y_fan), Vector2(sx, y_end)],
			"end": Vector2(sx, y_end)})
	return out


## Which port is under a face point (smallest first), "" for none.
static func port_at(lay: Dictionary, q: Vector2) -> String:
	var best := ""
	var best_a := INF
	for p in (lay.get("ports", []) as Array):
		var poly := PackedVector2Array(p["corners"])
		if poly.size() < 3:
			continue
		var r := Rect2(poly[0], Vector2.ZERO)
		for v in poly:
			r = r.expand(v)
		var grow := maxf(2.0, 0.0)
		if not r.grow(grow).has_point(q):
			continue
		var a := r.get_area()
		if a < best_a:
			best_a = a
			best = str(p["id"])
	return best


# ---------------------------------------------------------------------------
# SVG
# ---------------------------------------------------------------------------

## A wiring sheet: every face with ports side by side, a title and a key. In
## millimetres, on white, ready to print.
static func svg(d: Dictionary, faces: Array = []) -> String:
	if faces.is_empty():
		faces = faces_with_ports(d)
	var lays: Array = []
	for f in faces:
		var l := layout(d, str(f))
		if not l.is_empty():
			lays.append(l)
	var s: Dictionary = d["spec"]
	var x := 10.0
	var top := 30.0
	var h := 0.0
	var places: Array = []
	for l in lays:
		var b: Rect2 = l["bounds"]
		places.append(x - b.position.x)
		x += b.size.x + 12.0
		h = maxf(h, b.size.y)
	var w := maxf(x, 180.0)
	var total_h := top + h + 40.0
	var o := PackedStringArray()
	o.append('<?xml version="1.0" encoding="UTF-8"?>')
	o.append('<svg xmlns="http://www.w3.org/2000/svg" width="%smm" height="%smm" viewBox="0 0 %s %s" font-family="Inter, Arial, sans-serif">' % [_n(w), _n(total_h), _n(w), _n(total_h)])
	o.append('<rect x="0" y="0" width="%s" height="%s" fill="#ffffff"/>' % [_n(w), _n(total_h)])
	var title := str(s.get("name", "Controller"))
	o.append('<text x="10" y="12" font-size="7" font-weight="600" fill="#111">%s — wiring</text>' % _esc(title))
	var sub := " ".join([str(s.get("maker", "")), str(s.get("model", ""))]).strip_edges()
	o.append('<text x="10" y="20" font-size="3.6" fill="#555">%s</text>' % _esc(
		(sub + " · " if sub != "" else "") + "dimensions in mm, seen from outside"))
	for i in lays.size():
		var l: Dictionary = lays[i]
		var b: Rect2 = l["bounds"]
		# Face frame (y up) → sheet (y down): X = ox + u, Y = oy − v.
		var ox := float(places[i])
		var oy := top + (b.position.y + b.size.y)
		o.append(_face_svg(l, ox, oy))
	# Key.
	var ky := total_h - 10.0
	var kx := 10.0
	for k in [["L / L1", C_BLACK], ["L2", C_RED], ["N", C_WHITE], ["PE / G", C_GREEN], ["DC +", C_RED], ["DC −", C_BLACK], ["Data / IO", C_TEAL]]:
		o.append('<line x1="%s" y1="%s" x2="%s" y2="%s" stroke="#333" stroke-width="2.2"/>' % [_n(kx), _n(ky), _n(kx + 8), _n(ky)])
		o.append('<line x1="%s" y1="%s" x2="%s" y2="%s" stroke="%s" stroke-width="1.4"/>' % [_n(kx), _n(ky), _n(kx + 8), _n(ky), _hex(k[1])])
		o.append('<text x="%s" y="%s" font-size="3.2" fill="#333">%s</text>' % [_n(kx + 10), _n(ky + 1.1), _esc(str(k[0]))])
		kx += 30.0
	o.append('</svg>')
	return "\n".join(o)


## One already-laid-out face, dropped into a parent sheet. `ox` / `oy` are that
## sheet's y-down transform (X = ox + u, Y = oy − v), the same one `svg` uses.
static func face_svg(l: Dictionary, ox: float, oy: float) -> String:
	return _face_svg(l, ox, oy)


static func _face_svg(l: Dictionary, ox: float, oy: float) -> String:
	var o := PackedStringArray()
	var ts := float(l["text_mm"])
	var r: Rect2 = l["rect"]
	o.append('<g id="face_%s">' % str(l["face"]))
	o.append(_look_svg(l, ox, oy))
	if bool(l.get("title", true)):
		o.append('<text x="%s" y="%s" font-size="%s" font-weight="600" fill="#222">%s  %s × %s</text>' % [
			_n(ox + r.position.x), _n(oy - r.end.y - ts * 0.6), _n(ts * 1.1), _esc(str(FACE_WORDS.get(l["face"], l["face"])).to_upper()),
			_n(r.size.x), _n(r.size.y)])
	if bool(l["has_bay"]):
		var br: Rect2 = l["bay"]
		o.append('<rect x="%s" y="%s" width="%s" height="%s" fill="#1f2226" stroke="#0e1012" stroke-width="0.6"/>' % [
			_n(ox + br.position.x), _n(oy - br.end.y), _n(br.size.x), _n(br.size.y)])
	for p in (l["ports"] as Array):
		var pts := PackedStringArray()
		var ext := Rect2()
		var first := true
		for v in (p["corners"] as Array):
			pts.append("%s,%s" % [_n(ox + (v as Vector2).x), _n(oy - (v as Vector2).y)])
			ext = Rect2(v as Vector2, Vector2.ZERO) if first else ext.expand(v as Vector2)
			first = false
		var col: Color = p["color"]
		var dom := str(p.get("domain", ""))
		o.append('<polygon id="port_%s" points="%s" fill="%s" stroke="%s" stroke-width="0.4"/>' % [
			_esc(str(p["id"])), " ".join(pts), "#1f2226" if dom != "ui" else "#33383e", _hex(col.lightened(0.1))])
		var cen: Vector2 = p["centre"]
		var named := (p["pins"] as Array).filter(func(q): return str(q["role"]) != "").is_empty()
		var small := dom == "ui" and ext.size.x < 9.0
		if (named or (p["pins"] as Array).size() > 2) and not small:
			var top_y := -INF
			for v2 in (p["corners"] as Array):
				top_y = maxf(top_y, (v2 as Vector2).y)
			var on_body: Color = (l.get("look", {}) as Dictionary).get("color", Color(0.5, 0.5, 0.5))
			o.append('<text x="%s" y="%s" font-size="%s" text-anchor="middle" fill="%s">%s</text>' % [
				_n(ox + cen.x), _n(oy - top_y - ts * 0.3), _n(ts * 0.7), "#f4f6f8" if on_body.get_luminance() < 0.5 else "#222",
				_esc(str(p["label"]))])
		for pin in (p["pins"] as Array):
			var pp: Vector2 = pin["pos"]
			o.append('<circle cx="%s" cy="%s" r="%s" fill="#b08a2e" stroke="#333" stroke-width="0.2"/>' % [
				_n(ox + pp.x), _n(oy - pp.y), _n(maxf(ts * 0.18, 0.6))])
	for ld in (l["leads"] as Array):
		var pts2 := PackedStringArray()
		for v3 in (ld["pts"] as Array):
			pts2.append("%s,%s" % [_n(ox + (v3 as Vector2).x), _n(oy - (v3 as Vector2).y)])
		var col2: Color = ld["color"]
		o.append('<polyline points="%s" fill="none" stroke="#333" stroke-width="%s" stroke-linejoin="round"/>' % [" ".join(pts2), _n(ts * 0.42)])
		o.append('<polyline points="%s" fill="none" stroke="%s" stroke-width="%s" stroke-linejoin="round"/>' % [" ".join(pts2), _hex(col2), _n(ts * 0.26)])
		var e: Vector2 = ld["end"]
		o.append('<text transform="translate(%s %s) rotate(-90)" font-size="%s" text-anchor="end" dominant-baseline="middle" fill="#111">%s</text>' % [
			_n(ox + e.x), _n(oy - e.y + ts * 0.5), _n(ts * 0.8), _esc(str(ld["text"]))])
	o.append('</g>')
	return "\n".join(o)


## The body as the unit looks: a rounded box in its colour, a front plate or
## a two-tone split, bands, raised panels, printed texts. Face mm → sheet.
static func _look_svg(l: Dictionary, ox: float, oy: float) -> String:
	var r: Rect2 = l["rect"]
	var look: Dictionary = l.get("look", {})
	var col: Color = look.get("color", Color(0.93, 0.94, 0.95))
	var cr := float(look.get("corner_r", 0.0))
	var fc := r.get_center()
	var o := PackedStringArray()
	var x := ox + r.position.x
	var y := oy - r.end.y
	o.append('<rect x="%s" y="%s" width="%s" height="%s" rx="%s" fill="#000" fill-opacity="0.12"/>' % [
		_n(x + 1.2), _n(y + 1.6), _n(r.size.x), _n(r.size.y), _n(cr)])
	o.append('<rect x="%s" y="%s" width="%s" height="%s" rx="%s" fill="%s" stroke="%s" stroke-width="0.4"/>' % [
		_n(x), _n(y), _n(r.size.x), _n(r.size.y), _n(cr), _hex(col), _hex(col.darkened(0.35))])
	var plate: Dictionary = look.get("plate", {})
	if not plate.is_empty():
		var ins := float(plate.get("inset", 8.0))
		o.append('<rect x="%s" y="%s" width="%s" height="%s" rx="%s" fill="%s"/>' % [
			_n(x + ins), _n(y + ins), _n(r.size.x - 2.0 * ins), _n(r.size.y - 2.0 * ins), _n(maxf(cr - ins, 1.0)),
			_hex(plate.get("color", Color.WHITE))])
	var split_y := float(look.get("split_y", NAN))
	if not is_nan(split_y):
		var sy := oy - (fc.y + split_y)
		o.append('<path d="M%s %s H%s V%s a%s %s 0 0 1 -%s %s H%s a%s %s 0 0 1 -%s -%s Z" fill="%s"/>' % [
			_n(x), _n(sy), _n(x + r.size.x), _n(y + r.size.y - cr), _n(cr), _n(cr), _n(cr), _n(cr),
			_n(x + cr), _n(cr), _n(cr), _n(cr), _n(cr), _hex(look.get("split_color", col))])
	for bd in (look.get("bands", []) as Array):
		var xi := float(bd.get("x_inset", 0.0))
		var y1 := oy - (fc.y + float(bd["y1"]))
		var y0 := oy - (fc.y + float(bd["y0"]))
		o.append('<rect x="%s" y="%s" width="%s" height="%s" fill="%s"/>' % [
			_n(x + xi + 0.4), _n(y1), _n(r.size.x - 2.0 * xi - 0.8), _n(maxf(y0 - y1, 0.2)), _hex(bd.get("color", Color(0.9, 0.4, 0.1)))])
	for pn in (look.get("panels", []) as Array):
		var pr: Rect2 = pn["rect"]
		o.append('<rect x="%s" y="%s" width="%s" height="%s" rx="%s" fill="%s" stroke="#000" stroke-opacity="0.18" stroke-width="0.4"/>' % [
			_n(ox + fc.x + pr.position.x), _n(oy - (fc.y + pr.end.y)), _n(pr.size.x), _n(pr.size.y), _n(float(pn.get("r", 4.0))),
			_hex(pn.get("color", col))])
	for t in (look.get("texts", []) as Array):
		var text := str(t["text"]).strip_edges()
		if text == "":
			continue
		var size := float(t["size"])
		var max_w := float(t.get("max_w", 0.0))
		var align := str(t.get("align", "center"))
		var u := float(t["u"])
		var half: float = r.size.x * 0.5 - 2.0
		if max_w <= 0.0:
			max_w = (half - u) if align == "left" else ((half + u) if align == "right" else 2.0 * (half - absf(u)))
		# Inter runs about 0.55 em per character.
		var est := float(text.length()) * 0.55 * size
		if max_w > 0.5 and est > max_w:
			size *= max_w / est
		var anchor := "middle" if align == "center" else ("start" if align == "left" else "end")
		o.append('<text x="%s" y="%s" font-size="%s" font-weight="%s" text-anchor="%s" dominant-baseline="middle" fill="%s">%s</text>' % [
			_n(ox + fc.x + u), _n(oy - (fc.y + float(t["v"]))), _n(size * 0.95), "600" if bool(t.get("bold", false)) else "400",
			anchor, _hex(t.get("color", Color.WHITE)), _esc(text)])
	return "\n".join(o)


static func _n(v: float) -> String:
	return ("%.2f" % v).rstrip("0").rstrip(".")


static func _hex(c: Color) -> String:
	return "#" + c.to_html(false)


static func _esc(t: String) -> String:
	return t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")
