extends Control

## The wiring diagram page. Drawn from a WireSheet layout (the same one
## `WireSheet.svg` writes). Wheel zooms about the pointer, a drag on empty
## paper pans, a press selects a device and a drag moves it. The move is
## reported as the device's new bottom-left, in page millimetres; the host
## stores that and asks for a new layout. This view does not touch the graph.

signal device_selected(id: String)
signal device_moved(id: String, origin: Vector2)
signal conductor_selected(id: String)

const PAPER := Color("#f7f8fa")
const SEL := Color("#e8a317")
const BLUE := Color("#0c4c9a")
const BLUE_DK := Color("#08356e")
const ORANGE := Color("#e4570e")
const BRASS := Color("#c6a15a")
const BRASS_DK := Color("#8a7340")
const METAL := Color("#8d9399")
const INK := Color("#1c2430")
const DRAG_PX := 4.0

var lay: Dictionary = {}
var selected := ""
var conductor := ""
var scale_px := 1.0
var origin := Vector2.ZERO
var _press := {}


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	resized.connect(fit)


func set_layout(l: Dictionary) -> void:
	lay = l
	queue_redraw()


func fit() -> void:
	if lay.is_empty() or size.x < 10.0 or size.y < 10.0:
		return
	var b := WireSheet.ink_bounds(lay)
	if b.size.x < 1.0 or b.size.y < 1.0:
		return
	scale_px = minf(size.x / b.size.x, size.y / b.size.y) * 0.92
	var c := b.get_center()
	origin = size * 0.5 - Vector2(c.x, -c.y) * scale_px
	queue_redraw()


func to_px(q: Vector2) -> Vector2:
	return origin + Vector2(q.x, -q.y) * scale_px


func to_mm(px: Vector2) -> Vector2:
	var d := (px - origin) / scale_px
	return Vector2(d.x, -d.y)


func _gui_input(e: InputEvent) -> void:
	if lay.is_empty():
		return
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			var k := 1.12 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.12
			var before := to_mm(mb.position)
			scale_px = clampf(scale_px * k, 0.12, 12.0)
			origin += mb.position - to_px(before)
			queue_redraw()
			accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_MIDDLE:
			_press = {"pos": mb.position, "id": "", "moved": false, "pan": true} if mb.pressed else {}
			accept_event()
			return
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			var id := WireSheet.device_at(lay, to_mm(mb.position))
			var box := _box(id)
			var wire := ""
			if id == "":
				wire = WireSheet.conductor_at(lay, to_mm(mb.position), 10.0 / maxf(scale_px, 0.15))
			_press = {"pos": mb.position, "id": id, "wire": wire, "moved": false, "pan": false, "origin": box.position}
			if id != "":
				selected = id
				conductor = ""
				device_selected.emit(id)
				conductor_selected.emit("")
			else:
				conductor = wire
				conductor_selected.emit(wire)
				if wire != "":
					selected = ""
					device_selected.emit("")
			queue_redraw()
			accept_event()
		elif not _press.is_empty():
			var moved := bool(_press.get("moved", false))
			var id2 := str(_press.get("id", ""))
			var wire2 := str(_press.get("wire", ""))
			_press = {}
			if id2 == "" and wire2 == "" and not moved:
				selected = ""
				conductor = ""
				device_selected.emit("")
				conductor_selected.emit("")
			queue_redraw()
			accept_event()
	elif e is InputEventMouseMotion and not _press.is_empty():
		var mm := e as InputEventMouseMotion
		if mm.position.distance_to(_press["pos"]) > DRAG_PX:
			_press["moved"] = true
		if bool(_press["moved"]):
			var id3 := str(_press.get("id", ""))
			if id3 == "":
				origin += mm.relative
			else:
				var delta := (mm.position - (_press["pos"] as Vector2)) / scale_px * Vector2(1, -1)
				var at: Vector2 = (_press["origin"] as Vector2) + _snap(delta, mm)
				device_moved.emit(id3, at)
			queue_redraw()
			accept_event()


func _snap(v: Vector2, e: InputEvent) -> Vector2:
	var step := 5.0
	if e is InputEventWithModifiers:
		var em := e as InputEventWithModifiers
		if em.alt_pressed:
			return v
		if em.shift_pressed:
			step = 1.0
	return Vector2(snappedf(v.x, step), snappedf(v.y, step))


func _px_box(box: Rect2) -> Rect2:
	return Rect2(to_px(Vector2(box.position.x, box.end.y)), box.size * scale_px)


func _shadow(pr: Rect2) -> void:
	draw_rect(Rect2(pr.position + Vector2(3.0, 3.0), pr.size), Color(0.08, 0.1, 0.14, 0.14))


func _plate(pr: Rect2, title: String, caption: String, font: Font, bold: Font, ink: Color) -> void:
	if scale_px <= 0.32:
		return
	var fs := clampi(int(scale_px * 3.4), 9, 15)
	var band := maxf(pr.size.y * 0.07, 5.0)
	draw_rect(Rect2(pr.position, Vector2(pr.size.x, band)), ORANGE)
	draw_string(bold, Vector2(pr.position.x + 4.0, pr.position.y + band + fs + 2.0), title,
		HORIZONTAL_ALIGNMENT_CENTER, pr.size.x - 8.0, fs, ink)
	if caption != "":
		draw_string(font, Vector2(pr.position.x + 4.0, pr.position.y + band + fs * 2.15 + 2.0), caption,
			HORIZONTAL_ALIGNMENT_CENTER, pr.size.x - 8.0, maxi(fs - 2, 8), ink)


func _stud(at: Vector2, mark: String, font: Font) -> void:
	var r := clampf(scale_px * 3.2, 3.5, 8.0)
	draw_circle(at, r, BRASS_DK, true, -1.0, true)
	draw_circle(at, r * 0.72, BRASS, true, -1.0, true)
	if mark != "" and r > 4.5:
		draw_string(font, at + Vector2(-r, r * 0.28), mark, HORIZONTAL_ALIGNMENT_CENTER, r * 2.0,
			clampi(int(r * 1.1), 7, 11), Color("#3a2c12"))


func _draw_device(d: Dictionary, font: Font, bold: Font) -> void:
	var box: Rect2 = d["box"]
	var kind := str(d["kind"])
	var sym: Dictionary = d.get("symbol", {})
	var pr := _px_box(box)
	var name := str(d["name"])
	var cap := str(sym.get("caption", ""))
	var state := str(sym.get("state", ""))
	if str(sym.get("kind", "")) == "face":
		_shadow(pr)
		_draw_face(sym["face"], bold)
		_plate(pr, name, "", font, bold, Color.WHITE)
	elif kind == "panels":
		_shadow(pr)
		draw_rect(pr, Color("#d5d8de"))
		draw_rect(pr, Color("#8e95a0"), false, 1.4)
		var cell := pr.grow(-maxf(pr.size.x * 0.045, 3.0))
		cell.size.y -= maxf(pr.size.y * 0.08, 6.0)
		draw_rect(cell, Color("#163e78"))
		_draw_module_grid(box)
		var jb := Rect2(pr.get_center().x - pr.size.x * 0.12, pr.end.y - maxf(pr.size.y * 0.07, 5.0), pr.size.x * 0.24, maxf(pr.size.y * 0.05, 4.0))
		draw_rect(jb, Color("#2c3138"))
		if scale_px > 0.32:
			var fs := clampi(int(scale_px * 3.2), 9, 14)
			draw_string(bold, Vector2(cell.position.x, cell.position.y + fs + 2.0), cap,
				HORIZONTAL_ALIGNMENT_CENTER, cell.size.x, fs, Color.WHITE)
			draw_string(font, Vector2(pr.position.x, pr.end.y - 2.0), name,
				HORIZONTAL_ALIGNMENT_CENTER, pr.size.x, maxi(fs - 2, 8), INK)
	elif kind == "battery":
		_shadow(pr)
		draw_rect(pr, BLUE)
		draw_rect(pr, BLUE_DK, false, 1.4)
		_plate(pr, name, cap, font, bold, Color.WHITE)
		for p in (d["ports"] as Array):
			var mark := "+" if str(p["role"]).ends_with("+") else "−"
			_stud(to_px(p["pos"]), mark, bold)
	elif kind == "fuse":
		_shadow(pr)
		var cap_w := pr.size.x * 0.16
		draw_rect(Rect2(pr.position, Vector2(cap_w, pr.size.y)), METAL)
		draw_rect(Rect2(Vector2(pr.end.x - cap_w, pr.position.y), Vector2(cap_w, pr.size.y)), METAL)
		var body := Rect2(pr.position.x + cap_w, pr.position.y + pr.size.y * 0.12, pr.size.x - cap_w * 2.0, pr.size.y * 0.76)
		draw_rect(body, Color("#f4d03f"))
		draw_rect(body, Color("#b7950b"), false, 1.0)
		_center_words(body, cap if cap != "" else name, state, font, bold, INK)
	elif kind == "breaker":
		_shadow(pr)
		draw_rect(pr, Color("#2c3138"))
		var toggle := Rect2(pr.position.x + pr.size.x * 0.28, pr.position.y + pr.size.y * 0.12, pr.size.x * 0.44, pr.size.y * 0.34)
		draw_rect(toggle, ORANGE)
		_center_words(Rect2(pr.position.x, pr.get_center().y, pr.size.x, pr.size.y * 0.45), cap if cap != "" else name, state, font, bold, Color.WHITE)
	elif kind == "switch":
		_shadow(pr)
		draw_rect(pr, Color("#eef0f3"))
		draw_rect(pr, Color("#b7bdc6"), false, 1.0)
		var c := pr.get_center() + Vector2(0, -pr.size.y * 0.06)
		var rad := minf(pr.size.x, pr.size.y) * 0.28
		draw_circle(c, rad, Color("#d5d8dc"), true, -1.0, true)
		draw_arc(c, rad, -PI * 0.75, PI * 0.15, 18, Color("#5d6570"), 2.0, true)
		draw_line(c, c + Vector2(rad * 0.2, -rad * 0.85), Color("#c0392b"), maxf(2.0, scale_px * 0.8), true)
		_center_words(Rect2(pr.position.x, pr.end.y - pr.size.y * 0.28, pr.size.x, pr.size.y * 0.26), name, state, font, bold, INK)
	elif kind == "busbar":
		_shadow(pr)
		draw_rect(pr, Color("#b87333"))
		draw_rect(pr, Color("#7a4e22"), false, 1.2)
		var n := 5
		for i in n:
			var x := pr.position.x + pr.size.x * (float(i) + 0.5) / float(n)
			_stud(Vector2(x, pr.get_center().y), "", font)
		if scale_px > 0.35:
			draw_string(bold, Vector2(pr.position.x, pr.position.y - 2.0), name,
				HORIZONTAL_ALIGNMENT_CENTER, pr.size.x, clampi(int(scale_px * 3.0), 8, 13), INK)
	elif kind == "distributor":
		_shadow(pr)
		draw_rect(pr, Color("#3a414a"))
		for i in 4:
			var fw := pr.size.x * 0.12
			var fx := pr.position.x + pr.size.x * (0.12 + float(i) * 0.2)
			draw_rect(Rect2(fx, pr.position.y + pr.size.y * 0.22, fw, pr.size.y * 0.28), Color("#f4d03f"))
		_center_words(Rect2(pr.position.x, pr.get_center().y, pr.size.x, pr.size.y * 0.4), name, cap, font, bold, Color.WHITE)
	elif kind == "shunt":
		_shadow(pr)
		draw_rect(pr, Color("#5d6d7e"))
		draw_rect(pr, Color("#2c3e50"), false, 1.2)
		_stud(Vector2(pr.position.x + pr.size.x * 0.22, pr.get_center().y), "", font)
		_stud(Vector2(pr.position.x + pr.size.x * 0.78, pr.get_center().y), "", font)
		_center_words(pr, name, "", font, bold, Color.WHITE)
	elif kind == "monitor":
		_shadow(pr)
		draw_rect(pr, BLUE)
		var screen := pr.grow(-maxf(pr.size.x * 0.08, 3.0))
		screen.size.y *= 0.55
		draw_rect(screen, Color("#102033"))
		_center_words(Rect2(pr.position.x, screen.end.y, pr.size.x, pr.end.y - screen.end.y), name, cap, font, bold, Color.WHITE)
	else:
		_shadow(pr)
		var fill: Color = WireSheet.FILL.get(kind, Color("#e6e8eb"))
		draw_rect(pr, fill)
		draw_rect(pr, INK, false, 1.2)
		_center_words(pr, name, cap, font, bold, INK)
	if str(d["id"]) == selected:
		draw_rect(pr.grow(3.0), SEL, false, 2.0)


func _center_words(pr: Rect2, title: String, caption: String, font: Font, bold: Font, ink: Color) -> void:
	if scale_px <= 0.32 or title == "":
		return
	var fs := clampi(int(minf(pr.size.y * 0.34, scale_px * 3.6)), 8, 15)
	draw_string(bold, Vector2(pr.position.x, pr.get_center().y + fs * 0.15), title,
		HORIZONTAL_ALIGNMENT_CENTER, pr.size.x, fs, ink)
	if caption != "":
		draw_string(font, Vector2(pr.position.x, pr.get_center().y + fs * 1.15), caption,
			HORIZONTAL_ALIGNMENT_CENTER, pr.size.x, maxi(fs - 2, 8), ink)


func _draw_face(face: Dictionary, bold: Font) -> void:
	var r: Rect2 = face["rect"]
	var paper := Rect2(to_px(Vector2(r.position.x, r.end.y)), r.size * scale_px)
	draw_rect(paper, BLUE)
	draw_rect(paper, BLUE_DK, false, 1.4)
	if bool(face.get("has_bay", false)):
		var br: Rect2 = face["bay"]
		var bay := Rect2(to_px(Vector2(br.position.x, br.end.y)), br.size * scale_px)
		draw_rect(bay, Color("#2a2e33"))
		draw_rect(bay, Color("#1a1d21"), false, 1.0)
	var ts := float(face.get("text_mm", 3.0)) * scale_px
	var fs := clampi(int(ts * 0.72), 8, 13)
	for p in (face["ports"] as Array):
		var poly := PackedVector2Array()
		for v in (p["corners"] as Array):
			poly.append(to_px(v as Vector2))
		if poly.size() >= 3:
			draw_colored_polygon(poly, Color("#1a1d21"))
			var loop := poly.duplicate()
			loop.append(poly[0])
			draw_polyline(loop, Color("#4a515a"), 1.2, true)
		for pin in (p["pins"] as Array):
			var at := to_px(pin["pos"])
			var rad := maxf(ts * 0.2, 2.2)
			draw_circle(at, rad, BRASS_DK, true, -1.0, true)
			draw_circle(at, rad * 0.62, BRASS, true, -1.0, true)
	for ld in (face["leads"] as Array):
		var pts := PackedVector2Array()
		for v3 in (ld["pts"] as Array):
			pts.append(to_px(v3 as Vector2))
		if pts.size() < 2:
			continue
		var w := maxf(ts * 0.34, 2.0)
		draw_polyline(pts, Color.WHITE, w + 2.2, true)
		draw_polyline(pts, ld["color"], w, true)
		if scale_px > 0.45:
			var e := to_px(ld["end"] as Vector2)
			draw_set_transform(e + Vector2(fs * 0.4, 2.0), -PI * 0.5, Vector2.ONE)
			draw_string(bold, Vector2(-240, 0), str(ld["text"]), HORIZONTAL_ALIGNMENT_RIGHT, 240, fs, INK)
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_module_grid(box: Rect2) -> void:
	var inset := 8.0
	if box.size.x < inset * 3.0 or box.size.y < inset * 3.0:
		return
	var r := Rect2(box.position + Vector2(inset, inset), box.size - Vector2(inset * 2.0, inset * 2.0))
	var cols := 6
	var rows := 10
	var col := Color("#8fb4e0")
	for i in range(1, cols):
		var x := r.position.x + r.size.x * float(i) / float(cols)
		draw_line(to_px(Vector2(x, r.position.y)), to_px(Vector2(x, r.end.y)), col, 1.0)
	for j in range(1, rows):
		var y := r.position.y + r.size.y * float(j) / float(rows)
		draw_line(to_px(Vector2(r.position.x, y)), to_px(Vector2(r.end.x, y)), col, 1.0)


func _box(id: String) -> Rect2:
	for d in (lay.get("devices", []) as Array):
		if str(d["id"]) == id:
			return d["box"]
	return Rect2()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), PAPER)
	if lay.is_empty():
		return
	var font := UITheme.font("medium")
	var bold := UITheme.font("semibold")
	for c in (lay.get("conductors", []) as Array):
		var cd: Dictionary = c
		var pts := PackedVector2Array()
		var acc := Vector2.ZERO
		var wire: PackedVector2Array = cd["pts"]
		for p in wire:
			var px := to_px(p)
			pts.append(px)
			acc += px
		if pts.size() < 2:
			continue
		var col: Color = cd["color"]
		var hot := str(cd["id"]) == conductor
		var w := _cable_px(str(cd.get("gauge", "")))
		draw_polyline(pts, Color.WHITE, w + (5.0 if hot else 3.2), true)
		draw_polyline(pts, SEL if hot else col, w, true)
		var mid := acc / float(pts.size())
		_gauge_chip(mid, cd, bold, col)
	for d in (lay.get("devices", []) as Array):
		_draw_device(d, font, bold)
	var checks: Array = lay.get("checks", [])
	if not checks.is_empty():
		var b := WireSheet.ink_bounds(lay)
		var y := b.position.y - 8.0
		for ck in checks:
			var lv := str(ck.get("level", "warn"))
			var cc := Color("#9a3412") if lv == "warn" else (Color("#b91c1c") if lv == "error" else Color("#334155"))
			var at := to_px(Vector2(b.position.x, y))
			var fs := clampi(int(scale_px * 3.2), 10, 15)
			var text := str(ck["text"])
			var tw := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			var card := Rect2(at + Vector2(-6, -fs - 4), Vector2(tw + 16.0, fs + 10.0))
			draw_rect(card, Color("#fff7ed"))
			draw_rect(Rect2(card.position, Vector2(3.0, card.size.y)), ORANGE)
			draw_rect(card, Color("#fed7aa"), false, 1.0)
			draw_string(font, Vector2(card.position.x + 8.0, card.end.y - 5.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, cc)
			y -= 16.0


func _cable_px(gauge: String) -> float:
	var heavy := gauge.begins_with("6 ") or gauge.begins_with("4 ") or gauge.begins_with("2 ") or gauge.begins_with("1 ") or gauge.begins_with("1/") or gauge.begins_with("0")
	var mid := gauge.begins_with("8 ")
	var k := 2.8 if heavy else (2.3 if mid else 1.8)
	return clampf(scale_px * k, 2.2, 9.0)


func _gauge_chip(mid: Vector2, cd: Dictionary, bold: Font, col: Color) -> void:
	var label := str(cd.get("label", ""))
	if label == "":
		return
	var text := "%s  %.1f m" % [label, float(cd.get("length_m", 0.0))]
	var fs := clampi(int(scale_px * 3.0), 9, 14)
	var tw := bold.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var chip := Rect2(mid + Vector2(6.0, -fs - 3.0), Vector2(tw + 10.0, fs + 6.0))
	draw_rect(chip, Color(1, 1, 1, 0.94))
	draw_rect(Rect2(chip.position, Vector2(3.0, chip.size.y)), col)
	draw_rect(chip, col.darkened(0.15), false, 1.0)
	draw_string(bold, Vector2(chip.position.x + 6.0, chip.end.y - 3.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col.darkened(0.35))
