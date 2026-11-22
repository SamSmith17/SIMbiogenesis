class_name CtrlFaceDraw
extends RefCounted

## Draws one controller face (a CtrlSheet.layout) onto a CanvasItem so it
## reads as the unit: the body in its own colour with its corner radius, a
## front plate or a two-tone split, the maker's bands and raised panels,
## the printed texts, the wiring bay, every connector's outline with its
## pins, and the coloured leads fanned out below. Both the Controller Lab's
## Terminals view and the system wiring page draw their faces through this,
## so a Victron is Victron blue with its orange stripe on either.
##
## `to_px` maps face millimetres (y up) to the control's pixels; `scale_px`
## is pixels per mm. `opts`: selected (port id), drag (port id), drag_px
## (Vector2 mm offset of the dragged port), leads (bool), lead_labels (bool),
## dark (bool: the lab's dark paper), name (text over the unit), hidden_leads
## (bool: leave the fan out, the page draws its own cables from the lead ends).

const INK := Color(0.11, 0.13, 0.16)
const PIN := Color(0.80, 0.66, 0.30)
const PIN_DK := Color(0.52, 0.41, 0.17)


static func draw(ci: CanvasItem, lay: Dictionary, to_px: Callable, scale_px: float, opts: Dictionary = {}) -> void:
	var r: Rect2 = lay["rect"]
	var look: Dictionary = lay.get("look", {})
	# The look is in the face's own frame (centre at 0); the page may have
	# shifted the face, so everything in it moves by the rect's centre.
	var fc := r.get_center()
	var body_col: Color = look.get("color", Color(0.16, 0.5, 0.84))
	var pr := _px_rect(to_px, r)
	var cr := float(look.get("corner_r", 0.0)) * scale_px
	var font := UITheme.font("medium")
	var bold := UITheme.font("semibold")
	# Shadow and body.
	_rrect(ci, Rect2(pr.position + Vector2(2.5, 3.5), pr.size), cr, Color(0, 0, 0, 0.16))
	_rrect(ci, pr, cr, body_col)
	var plate: Dictionary = look.get("plate", {})
	if not plate.is_empty():
		var ins := float(plate.get("inset", 8.0)) * scale_px
		_rrect(ci, pr.grow(-ins), maxf(cr - ins, 2.0), plate.get("color", Color.WHITE))
	var split_y := float(look.get("split_y", NAN))
	if not is_nan(split_y):
		var sy: float = (to_px.call(fc + Vector2(0, split_y)) as Vector2).y
		var low := Rect2(pr.position.x, sy, pr.size.x, pr.end.y - sy)
		_rrect_bottom(ci, low, cr, look.get("split_color", body_col))
	for bd in (look.get("bands", []) as Array):
		var xi := float(bd.get("x_inset", 0.0))
		var a: Vector2 = to_px.call(Vector2(r.position.x + xi, fc.y + float(bd["y1"])))
		var b: Vector2 = to_px.call(Vector2(r.end.x - xi, fc.y + float(bd["y0"])))
		var band := Rect2(a, b - a).abs()
		band = band.intersection(pr.grow(-1.0))
		if band.size.x > 0.0 and band.size.y > 0.0:
			ci.draw_rect(band, bd.get("color", Color(0.9, 0.4, 0.1)))
	for pn in (look.get("panels", []) as Array):
		var prect: Rect2 = pn["rect"]
		var pp := _px_rect(to_px, Rect2(prect.position + fc, prect.size))
		var pcol: Color = pn.get("color", body_col)
		_rrect(ci, Rect2(pp.position + Vector2(0, 1.5), pp.size), float(pn.get("r", 4.0)) * scale_px, Color(0, 0, 0, 0.18))
		_rrect(ci, pp, float(pn.get("r", 4.0)) * scale_px, pcol)
	# Vertical sheen along the left edge, like a moulded case.
	ci.draw_rect(Rect2(pr.position + Vector2(cr * 0.5, cr), Vector2(maxf(scale_px * 1.2, 1.0), pr.size.y - cr * 2.0)),
		Color(1, 1, 1, 0.10))
	# The bay: a dark recess with a rim.
	if bool(lay.get("has_bay", false)):
		var br: Rect2 = lay["bay"]
		var bpr := _px_rect(to_px, br)
		ci.draw_rect(bpr.grow(1.5), body_col.darkened(0.35))
		ci.draw_rect(bpr, Color(0.13, 0.14, 0.16))
		ci.draw_rect(Rect2(bpr.position, Vector2(bpr.size.x, maxf(scale_px * 1.5, 1.0))), Color(0, 0, 0, 0.35))
	# Printed texts.
	for t in (look.get("texts", []) as Array):
		var text := str(t["text"])
		if text.strip_edges() == "":
			continue
		var size_mm := float(t["size"])
		var f := bold if bool(t.get("bold", false)) else font
		var max_w := float(t.get("max_w", 0.0))
		var ref := f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 64).x / 64.0  # width per mm of size
		var half: float = r.size.x * 0.5 - 2.0
		var u := float(t["u"])
		var align := str(t.get("align", "center"))
		if max_w <= 0.0:
			match align:
				"left":
					max_w = half - u
				"right":
					max_w = half + u
				_:
					max_w = 2.0 * (half - absf(u))
		if max_w > 0.5 and ref * size_mm > max_w:
			size_mm = max_w / ref
		var fs := size_mm * scale_px
		if fs < 4.0:
			continue
		var at: Vector2 = to_px.call(fc + Vector2(u, float(t["v"])))
		var w_px := ref * fs
		var x := at.x
		if align == "center":
			x -= w_px * 0.5
		elif align == "right":
			x -= w_px
		ci.draw_string(f, Vector2(x, at.y + fs * 0.36), text, HORIZONTAL_ALIGNMENT_LEFT, -1, int(round(fs)), t.get("color", Color.WHITE))
	# Connectors and pins.
	var ts := float(lay.get("text_mm", 3.0)) * scale_px
	var sel := str(opts.get("selected", ""))
	var drag := str(opts.get("drag", ""))
	var drag_mm: Vector2 = opts.get("drag_mm", Vector2.ZERO)
	var dark := bool(opts.get("dark", false))
	var fs_port := clampi(int(ts * 0.72), 8, 14)
	for p in (lay["ports"] as Array):
		var off := drag_mm if str(p["id"]) == drag else Vector2.ZERO
		var poly := PackedVector2Array()
		for v in (p["corners"] as Array):
			poly.append(to_px.call((v as Vector2) + off))
		if poly.size() < 3:
			continue
		var col: Color = p["color"]
		var is_sel := str(p["id"]) == sel
		var dom := str(p.get("domain", ""))
		var face_col := Color(0.12, 0.13, 0.15) if dom != "ui" else Color(0.2, 0.22, 0.25)
		ci.draw_colored_polygon(poly, face_col)
		var loop := poly.duplicate()
		loop.append(poly[0])
		ci.draw_polyline(loop, Color(1.0, 0.78, 0.2) if is_sel else col.lightened(0.1), 2.4 if is_sel else 1.2, true)
		var labelled := (p["pins"] as Array).filter(func(q): return str(q["role"]) != "").is_empty() or (p["pins"] as Array).size() > 2
		if dom == "ui" and not is_sel:
			# An LED or a button is a few mm across: its name would land on its neighbour's.
			var ext := Rect2(poly[0], Vector2.ZERO)
			for v4 in poly:
				ext = ext.expand(v4)
			if ext.size.x < 9.0 * scale_px:
				labelled = false
		if labelled and scale_px > 0.8:
			var top := INF
			for v2 in poly:
				top = minf(top, v2.y)
			var cen: Vector2 = to_px.call((p["centre"] as Vector2) + off)
			ci.draw_string(font, Vector2(cen.x - 200, top - 3), str(p["label"]), HORIZONTAL_ALIGNMENT_CENTER, 400, fs_port - 1,
				Color(1.0, 0.78, 0.2) if is_sel else (Color(0.85, 0.87, 0.9) if dark else Color(0.95, 0.96, 0.98)))
		for pin in (p["pins"] as Array):
			var pp: Vector2 = to_px.call((pin["pos"] as Vector2) + off)
			var rad := maxf(ts * 0.19, 2.2)
			ci.draw_circle(pp, rad, PIN_DK, true, -1.0, true)
			ci.draw_circle(pp, rad * 0.62, PIN, true, -1.0, true)
	# Leads.
	if bool(opts.get("leads", true)):
		var labels := bool(opts.get("lead_labels", true))
		for ld in (lay["leads"] as Array):
			if str(ld["port"]) == drag and drag_mm != Vector2.ZERO:
				continue
			var pts := PackedVector2Array()
			for v3 in (ld["pts"] as Array):
				pts.append(to_px.call(v3 as Vector2))
			if pts.size() < 2:
				continue
			var w := maxf(ts * 0.3, 2.0)
			ci.draw_polyline(pts, Color(0.2, 0.22, 0.25) if not dark else Color(0.75, 0.77, 0.8), w + 2.0, true)
			ci.draw_polyline(pts, ld["color"], w, true)
			if labels and scale_px > 0.45:
				var e: Vector2 = to_px.call(ld["end"] as Vector2)
				var fs := clampi(int(ts * 0.72), 8, 13)
				ci.draw_set_transform(e + Vector2(fs * 0.4, 2.0), -PI * 0.5, Vector2.ONE)
				ci.draw_string(bold, Vector2(-240, 0), str(ld["text"]), HORIZONTAL_ALIGNMENT_RIGHT, 240, fs,
					Color(0.92, 0.93, 0.95) if dark else INK)
				ci.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	var nm := str(opts.get("name", ""))
	if nm != "" and scale_px > 0.3:
		var fs2 := clampi(int(scale_px * 3.4), 9, 15)
		ci.draw_string(bold, Vector2(pr.position.x, pr.position.y - 6.0), nm, HORIZONTAL_ALIGNMENT_CENTER, pr.size.x, fs2,
			Color(0.9, 0.92, 0.95) if dark else INK)


static func _px_rect(to_px: Callable, r: Rect2) -> Rect2:
	var a: Vector2 = to_px.call(Vector2(r.position.x, r.end.y))
	var b: Vector2 = to_px.call(Vector2(r.end.x, r.position.y))
	return Rect2(a, b - a).abs()


## A rounded rectangle, anti-aliased at any size.
static func _rrect(ci: CanvasItem, r: Rect2, radius: float, col: Color) -> void:
	var rr := minf(radius, minf(r.size.x, r.size.y) * 0.5)
	if rr < 1.0:
		ci.draw_rect(r, col)
		return
	var sb := StyleBoxFlat.new()
	sb.bg_color = col
	sb.set_corner_radius_all(int(round(rr)))
	sb.anti_aliasing = true
	ci.draw_style_box(sb, r)


## A rectangle rounded only at its bottom corners (the lower half of a split body).
static func _rrect_bottom(ci: CanvasItem, r: Rect2, radius: float, col: Color) -> void:
	var rr := minf(radius, minf(r.size.x, r.size.y) * 0.5)
	if rr < 1.0:
		ci.draw_rect(r, col)
		return
	var sb := StyleBoxFlat.new()
	sb.bg_color = col
	sb.corner_radius_bottom_left = int(round(rr))
	sb.corner_radius_bottom_right = int(round(rr))
	sb.anti_aliasing = true
	ci.draw_style_box(sb, r)
