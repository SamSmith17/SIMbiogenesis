extends Control

## The wiring diagram page. Drawn from a WireSheet layout (the same one
## `WireSheet.svg` writes): the gear on its shelf, the cables dropping into
## the trough below and climbing to where they land, every run as a
## rounded cable whose thickness follows its gauge, and the protection in
## the line drawn as the part it is (an ANL fuse holder, a battery switch,
## a shunt, a bus). Wheel zooms about the pointer, a drag on empty paper
## pans, a press selects a device and a drag moves it. The move is reported
## as the device's new bottom-left, in page millimetres; the host stores
## that and asks for a new layout. This view does not touch the graph.

signal device_selected(id: String)
signal device_moved(id: String, origin: Vector2)
signal conductor_selected(id: String)

const FACE_DRAW := preload("res://scenes/ui/kit/ctrl_face_draw.gd")

const PAPER := Color("#f5f6f8")
const GRID := Color(0.0, 0.1, 0.2, 0.05)
const SEL := Color("#e8a317")
const INK := Color("#1c2430")
const INK_SOFT := Color("#5b6675")
const BLUE := Color("#1f5fa8")
const BLUE_DK := Color("#163f73")
const ORANGE := Color("#e4570e")
const BRASS := Color("#cfa85a")
const BRASS_DK := Color("#8a6f34")
const COPPER := Color("#b87333")
const COPPER_DK := Color("#7a4a1f")
const METAL := Color("#9aa1a9")
const METAL_DK := Color("#5c636b")
const DRAG_PX := 4.0
const FILLET_MM := 14.0

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
	scale_px = minf(size.x / (b.size.x + 60.0), size.y / (b.size.y + 60.0))
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


# ---------------------------------------------------------------------------
# Drawing helpers
# ---------------------------------------------------------------------------

func _px_box(box: Rect2) -> Rect2:
	return Rect2(to_px(Vector2(box.position.x, box.end.y)), box.size * scale_px)


func _rrect(r: Rect2, radius: float, col: Color) -> void:
	FACE_DRAW._rrect(self, r, radius, col)


func _shadow(pr: Rect2, radius: float = 0.0) -> void:
	_rrect(Rect2(pr.position + Vector2(2.5, 3.5), pr.size), radius, Color(0.08, 0.1, 0.14, 0.16))


func _fs(mm: float, lo: int = 8, hi: int = 16) -> int:
	return clampi(int(round(mm * scale_px)), lo, hi)


## A stud: a brass post with a coloured insulator ring.
func _stud(at: Vector2, pole: String, r_mm: float = 4.2) -> void:
	var r := clampf(scale_px * r_mm, 3.5, 11.0)
	var ring := Color("#c0392b") if pole == "+" else (Color("#2c3138") if pole == "-" else METAL_DK)
	draw_circle(at, r * 1.35, ring, true, -1.0, true)
	draw_circle(at, r, BRASS_DK, true, -1.0, true)
	draw_circle(at, r * 0.68, BRASS, true, -1.0, true)
	draw_circle(at + Vector2(-r * 0.2, -r * 0.2), r * 0.25, Color(1, 1, 1, 0.45), true, -1.0, true)


## A hex nut.
func _nut(at: Vector2, r: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 6:
		var a := PI / 6.0 + TAU * float(i) / 6.0
		pts.append(at + Vector2(cos(a), sin(a)) * r)
	draw_colored_polygon(pts, col)
	var loop := pts.duplicate()
	loop.append(pts[0])
	draw_polyline(loop, col.darkened(0.4), 1.0, true)
	draw_circle(at, r * 0.42, col.darkened(0.3), true, -1.0, true)


func _center_words(pr: Rect2, title: String, caption: String, font: Font, bold: Font, ink: Color, title_mm: float = 3.6) -> void:
	if scale_px * title_mm < 2.6 or title == "":
		return
	var fs := _fs(title_mm, 8, 15)
	draw_string(bold, Vector2(pr.position.x, pr.get_center().y + fs * 0.36 - (fs * 0.55 if caption != "" else 0.0)), title,
		HORIZONTAL_ALIGNMENT_CENTER, pr.size.x, fs, ink)
	if caption != "":
		draw_string(font, Vector2(pr.position.x, pr.get_center().y + fs * 1.15), caption,
			HORIZONTAL_ALIGNMENT_CENTER, pr.size.x, maxi(fs - 2, 8), ink)


# ---------------------------------------------------------------------------
# Devices
# ---------------------------------------------------------------------------

func _draw_device(d: Dictionary, font: Font, bold: Font) -> void:
	var box: Rect2 = d["box"]
	var kind := str(d["kind"])
	var sym: Dictionary = d.get("symbol", {})
	var pr := _px_box(box)
	var name := str(d["name"])
	var cap := str(sym.get("caption", ""))
	var state := str(sym.get("state", ""))
	match str(sym.get("kind", "")):
		"face":
			FACE_DRAW.draw(self, sym["face"], Callable(self, "to_px"), scale_px,
				{"leads": true, "lead_labels": false, "name": name, "dark": false})
		_:
			match kind:
				"panels":
					_draw_panel(d, pr, name, cap, str(sym.get("module", "")), font, bold)
				"battery":
					_draw_battery(d, pr, name, cap, font, bold)
				"fuse":
					_draw_fuse(pr, cap if cap != "" else name, state, font, bold)
				"breaker":
					_draw_breaker(pr, cap if cap != "" else name, state, font, bold)
				"switch":
					_draw_switch(pr, name, state, font, bold)
				"busbar":
					_draw_busbar(pr, name, bold)
				"distributor":
					_draw_distributor(pr, name, font, bold)
				"shunt":
					_draw_shunt(d, pr, name, font, bold)
				"monitor":
					_draw_monitor(pr, name, cap, font, bold)
				_:
					_shadow(pr, 3.0)
					_rrect(pr, 3.0, Color("#e6e8eb"))
					draw_rect(pr, INK, false, 1.2)
					_center_words(pr, name, cap, font, bold, INK)
	if str(d["id"]) == selected:
		_rrect(pr.grow(5.0), 6.0, Color(SEL.r, SEL.g, SEL.b, 0.18))
		draw_rect(pr.grow(4.0), SEL, false, 2.0)


func _draw_panel(d: Dictionary, pr: Rect2, name: String, cap: String, module: String, font: Font, bold: Font) -> void:
	_shadow(pr, 2.0)
	# Frame.
	_rrect(pr, scale_px * 2.0, Color("#c9ced4"))
	draw_rect(pr, Color("#8e95a0"), false, 1.2)
	var fw := maxf(pr.size.x * 0.035, 2.5)
	var glass := pr.grow(-fw)
	draw_rect(glass, Color("#0f2d5e"))
	# Cells: dark blue squares with pale gaps, a little lighter toward the top.
	var cols := 6
	var rows := 10
	var gap := maxf(scale_px * 0.9, 1.0)
	var cw := (glass.size.x - gap * float(cols + 1)) / float(cols)
	var ch := (glass.size.y - gap * float(rows + 1)) / float(rows)
	if cw > 2.0 and ch > 2.0:
		for j in rows:
			for i in cols:
				var cell := Rect2(glass.position.x + gap + float(i) * (cw + gap), glass.position.y + gap + float(j) * (ch + gap), cw, ch)
				var tint := lerpf(0.0, 0.08, float(j) / float(rows - 1))
				draw_rect(cell, Color(0.11 - tint * 0.3, 0.26 - tint, 0.52 - tint * 0.6))
				if cw > 7.0:
					# busbar lines down each cell
					for k in 2:
						var x := cell.position.x + cell.size.x * (0.33 + 0.34 * float(k))
						draw_line(Vector2(x, cell.position.y), Vector2(x, cell.end.y), Color(0.75, 0.8, 0.88, 0.55), 1.0)
		# glass sheen
		draw_line(glass.position + Vector2(glass.size.x * 0.1, glass.size.y * 0.92), glass.position + Vector2(glass.size.x * 0.9, glass.size.y * 0.08),
			Color(1, 1, 1, 0.07), maxf(glass.size.x * 0.12, 4.0), true)
	# Junction box behind the module, pigtails to the MC4 ends (the ports).
	var jb := Rect2(pr.get_center().x - pr.size.x * 0.11, pr.end.y - pr.size.y * 0.02, pr.size.x * 0.22, maxf(pr.size.y * 0.045, 4.0))
	_rrect(jb, 2.0, Color("#2c3138"))
	for p in (d["ports"] as Array):
		var end := to_px(p["pos"])
		var plus := str(p["role"]).ends_with("+")
		var from := Vector2(jb.get_center().x + (-1.0 if plus else 1.0) * jb.size.x * 0.25, jb.end.y)
		var w := maxf(scale_px * 2.2, 2.0)
		var pts := PackedVector2Array([from, Vector2(end.x, from.y + (end.y - from.y) * 0.45), end])
		var smooth := WireSheet.fillet(pts, 8.0 * scale_px, 5)
		draw_polyline(smooth, Color(0.2, 0.22, 0.25), w + 1.5, true)
		draw_polyline(smooth, Color("#c0392b") if plus else Color("#2c3138"), w, true)
		# MC4 connector body at the end
		var cl := maxf(scale_px * 7.0, 5.0)
		var cwid := maxf(scale_px * 3.4, 3.0)
		_rrect(Rect2(end.x - cwid * 0.5, end.y - cl, cwid, cl), cwid * 0.4, Color("#23272c"))
		draw_rect(Rect2(end.x - cwid * 0.5, end.y - cl * 0.55, cwid, cl * 0.2), Color(0.75, 0.78, 0.82, 0.6))
	if scale_px * 3.0 > 2.6:
		var fs := _fs(3.2, 9, 14)
		# The module's name and nameplate over the frame (the junction box and
		# pigtails take the bottom rail), the string's summary once, at the row's head.
		draw_string(bold, Vector2(pr.position.x, pr.position.y - 5.0), name, HORIZONTAL_ALIGNMENT_CENTER, pr.size.x, maxi(fs - 1, 8), INK)
		if module != "":
			draw_string(font, Vector2(pr.position.x, pr.position.y - 5.0 - fs), module, HORIZONTAL_ALIGNMENT_CENTER, pr.size.x, maxi(fs - 2, 8), INK_SOFT)
		if cap != "" and _string_head(str(d["id"])):
			draw_string(bold, Vector2(pr.position.x, pr.position.y - 7.0 - fs * 2.0), cap, HORIZONTAL_ALIGNMENT_LEFT, -1, maxi(fs - 1, 8), INK_SOFT)


## The first module of a string: nothing feeds its positive from another module.
func _string_head(id: String) -> bool:
	for c in (lay.get("conductors", []) as Array):
		var cd: Dictionary = c
		if str(cd.get("group", "")) != "array":
			continue
		if (str(cd["b"]) == id and str(cd["hb"]) == "positive") or (str(cd["a"]) == id and str(cd["ha"]) == "positive"):
			return false
	return true


func _draw_battery(d: Dictionary, pr: Rect2, name: String, cap: String, font: Font, bold: Font) -> void:
	_shadow(pr, 4.0)
	var case_col := Color("#20314a")
	_rrect(pr, scale_px * 3.0, case_col)
	# Lid with a lighter top band and a seam.
	var lid := Rect2(pr.position, Vector2(pr.size.x, maxf(pr.size.y * 0.16, 6.0)))
	_rrect(lid, scale_px * 3.0, Color("#2b4062"))
	draw_line(Vector2(pr.position.x + 2, lid.end.y), Vector2(pr.end.x - 2, lid.end.y), Color(0, 0, 0, 0.35), 1.2)
	# Label plate.
	var plate := Rect2(pr.position.x + pr.size.x * 0.12, lid.end.y + pr.size.y * 0.14, pr.size.x * 0.76, pr.size.y * 0.52)
	_rrect(plate, 3.0, Color("#eef1f4"))
	draw_rect(Rect2(plate.position, Vector2(plate.size.x, maxf(plate.size.y * 0.16, 3.0))), ORANGE)
	_center_words(Rect2(plate.position.x, plate.position.y + plate.size.y * 0.16, plate.size.x, plate.size.y * 0.84), name, cap, font, bold, INK, 3.4)
	# Vent caps along the lid.
	var n := 3
	for i in n:
		var x := pr.position.x + pr.size.x * (0.32 + 0.18 * float(i))
		draw_circle(Vector2(x, lid.get_center().y), maxf(scale_px * 2.2, 2.0), Color("#111820"), true, -1.0, true)
	# The studs on the lid (the ports), with their pole mark beside them.
	for p in (d["ports"] as Array):
		if str(p["handle"]) == "data":
			continue
		var at := to_px(p["pos"])
		var plus := str(p["role"]).ends_with("+")
		# a square terminal base
		var bs := maxf(scale_px * 7.0, 6.0)
		_rrect(Rect2(at.x - bs * 0.5, at.y - bs * 0.3, bs, bs * 0.6), 1.5, Color("#15202e"))
		_stud(at, "+" if plus else "-", 4.4)
		if scale_px > 0.5:
			var fs := _fs(4.0, 9, 16)
			draw_string(bold, at + Vector2((-1.0 if plus else 1.0) * (bs * 0.8 + fs * 0.5), fs * 0.35) - Vector2(fs * 0.3, 0),
				"+" if plus else "−", HORIZONTAL_ALIGNMENT_CENTER, fs, fs, Color("#e74c3c") if plus else Color("#1c2430"))


func _draw_fuse(pr: Rect2, cap: String, state: String, font: Font, bold: Font) -> void:
	# An ANL fuse holder: black base, two bolt posts, a brass fuse strip under a smoked cover.
	_shadow(pr, 3.0)
	var base := Rect2(pr.position.x, pr.position.y + pr.size.y * 0.1, pr.size.x, pr.size.y * 0.8)
	_rrect(base, scale_px * 2.5, Color("#23272c"))
	var strip := Rect2(pr.position.x + pr.size.x * 0.17, pr.get_center().y - pr.size.y * 0.1, pr.size.x * 0.66, pr.size.y * 0.2)
	var blown := state != ""
	draw_rect(strip, Color("#8a6f34") if blown else BRASS)
	if blown:
		draw_line(strip.get_center() + Vector2(-strip.size.x * 0.08, -strip.size.y), strip.get_center() + Vector2(strip.size.x * 0.08, strip.size.y), Color("#23272c"), 2.0)
	for sx in [0.17, 0.83]:
		var at := Vector2(pr.position.x + pr.size.x * sx, pr.get_center().y)
		_nut(at, maxf(pr.size.y * 0.17, 4.0), Color("#b9bec4"))
	# Smoked cover window.
	var cover := Rect2(pr.position.x + pr.size.x * 0.27, pr.position.y, pr.size.x * 0.46, pr.size.y)
	_rrect(cover, scale_px * 2.0, Color(0.55, 0.6, 0.66, 0.35))
	draw_rect(cover, Color(0.75, 0.8, 0.86, 0.7), false, 1.0)
	if scale_px * 3.2 > 2.6:
		var fs := _fs(3.4, 8, 14)
		draw_string(bold, Vector2(cover.position.x, cover.get_center().y + fs * 0.36), cap, HORIZONTAL_ALIGNMENT_CENTER, cover.size.x, fs, Color("#f7f9fb"))
		var below := "FUSE" if state == "" else state.to_upper()
		draw_string(font, Vector2(pr.position.x, pr.end.y + fs + 1.0), below, HORIZONTAL_ALIGNMENT_CENTER, pr.size.x, maxi(fs - 2, 8),
			Color("#b91c1c") if state != "" else INK_SOFT)


func _draw_breaker(pr: Rect2, cap: String, state: String, font: Font, bold: Font) -> void:
	_shadow(pr, 3.0)
	_rrect(pr, scale_px * 2.5, Color("#2c3138"))
	draw_rect(pr.grow(-maxf(scale_px * 1.0, 1.0)), Color("#3c434b"), false, 1.0)
	var tripped := state != ""
	var toggle := Rect2(pr.position.x + pr.size.x * 0.3, pr.position.y + pr.size.y * (0.42 if tripped else 0.12), pr.size.x * 0.4, pr.size.y * 0.42)
	_rrect(toggle, 2.0, Color("#c0392b") if tripped else Color("#1f6fd6"))
	draw_line(Vector2(toggle.position.x + 3, toggle.get_center().y), Vector2(toggle.end.x - 3, toggle.get_center().y), Color(1, 1, 1, 0.5), 1.5)
	for sx in [0.08, 0.92]:
		_nut(Vector2(pr.position.x + pr.size.x * sx, pr.get_center().y), maxf(pr.size.y * 0.13, 3.0), Color("#b9bec4"))
	if scale_px * 3.2 > 2.6:
		var fs := _fs(3.2, 8, 13)
		draw_string(bold, Vector2(pr.position.x, pr.end.y - 3.0), cap, HORIZONTAL_ALIGNMENT_CENTER, pr.size.x, fs, Color("#f7f9fb"))
		draw_string(font, Vector2(pr.position.x, pr.end.y + fs + 1.0), "TRIPPED" if tripped else "BREAKER", HORIZONTAL_ALIGNMENT_CENTER, pr.size.x,
			maxi(fs - 2, 8), Color("#b91c1c") if tripped else INK_SOFT)


func _draw_switch(pr: Rect2, name: String, state: String, font: Font, bold: Font) -> void:
	# A battery disconnect: square base, red rotary knob with a bar handle.
	_shadow(pr, 3.0)
	_rrect(pr, scale_px * 2.5, Color("#1e2328"))
	var c := pr.get_center()
	var rad := minf(pr.size.x, pr.size.y) * 0.4
	draw_circle(c, rad * 1.1, Color("#0f1215"), true, -1.0, true)
	draw_circle(c, rad, Color("#c0392b"), true, -1.0, true)
	draw_circle(c + Vector2(-rad * 0.25, -rad * 0.25), rad * 0.35, Color(1, 1, 1, 0.12), true, -1.0, true)
	var open := state != ""
	var ang := (PI * 0.5 if open else 0.0)
	var dir := Vector2(cos(ang), sin(ang))
	draw_line(c - dir * rad * 0.75, c + dir * rad * 0.75, Color("#7b1d14"), maxf(rad * 0.32, 3.0), true)
	draw_line(c - dir * rad * 0.75, c + dir * rad * 0.75, Color("#e74c3c"), maxf(rad * 0.16, 1.5), true)
	if scale_px * 3.0 > 2.6:
		var fs := _fs(3.0, 8, 12)
		draw_string(font, Vector2(pr.position.x, pr.end.y + fs + 1.0), ("OFF" if open else "ON") + " · " + name, HORIZONTAL_ALIGNMENT_CENTER, pr.size.x,
			fs, Color("#b91c1c") if open else INK_SOFT)


func _draw_busbar(pr: Rect2, name: String, bold: Font) -> void:
	_shadow(pr, 1.5)
	var base := Rect2(pr.position.x - 3.0, pr.position.y - 3.0, pr.size.x + 6.0, pr.size.y + 6.0)
	_rrect(base, 2.0, Color("#23272c"))
	draw_rect(pr, COPPER)
	draw_rect(Rect2(pr.position, Vector2(pr.size.x, pr.size.y * 0.3)), Color(1, 1, 1, 0.14))
	draw_rect(pr, COPPER_DK, false, 1.0)
	var n := 5
	for i in n:
		var x := pr.position.x + pr.size.x * (float(i) + 0.5) / float(n)
		_nut(Vector2(x, pr.get_center().y), maxf(pr.size.y * 0.3, 3.0), Color("#c7ccd2"))
	if scale_px * 3.0 > 2.6:
		draw_string(bold, Vector2(pr.position.x, pr.position.y - 6.0), name, HORIZONTAL_ALIGNMENT_CENTER, pr.size.x, _fs(3.0, 8, 13), INK)


func _draw_distributor(pr: Rect2, name: String, font: Font, bold: Font) -> void:
	# A Lynx-style distributor: blue housing, fuse windows, studs along the bottom edge.
	_shadow(pr, 3.0)
	_rrect(pr, scale_px * 3.0, BLUE)
	draw_rect(Rect2(pr.position + Vector2(pr.size.x * 0.06, pr.size.y * 0.1), Vector2(pr.size.x * 0.88, maxf(pr.size.y * 0.08, 2.0))), ORANGE)
	for i in 4:
		var fw := pr.size.x * 0.13
		var fx := pr.position.x + pr.size.x * (0.1 + float(i) * 0.21)
		var win := Rect2(fx, pr.position.y + pr.size.y * 0.3, fw, pr.size.y * 0.42)
		_rrect(win, 1.5, Color("#0e1a2b"))
		draw_rect(Rect2(win.position.x + win.size.x * 0.2, win.get_center().y - win.size.y * 0.12, win.size.x * 0.6, win.size.y * 0.24), BRASS)
	if scale_px * 3.0 > 2.6:
		var fs := _fs(3.0, 8, 13)
		draw_string(bold, Vector2(pr.position.x, pr.end.y - 2.0), name, HORIZONTAL_ALIGNMENT_CENTER, pr.size.x, fs, Color("#f7f9fb"))


func _draw_shunt(d: Dictionary, pr: Rect2, name: String, font: Font, bold: Font) -> void:
	# A shunt: a dark manganin block between two heavy bolts, a small sense block under it.
	_shadow(pr, 2.0)
	var bar := Rect2(pr.position.x + pr.size.x * 0.1, pr.position.y + pr.size.y * 0.25, pr.size.x * 0.8, pr.size.y * 0.5)
	_rrect(pr, scale_px * 2.0, Color("#3a4654"))
	draw_rect(bar, Color("#8a949e"))
	draw_rect(Rect2(bar.position, Vector2(bar.size.x, bar.size.y * 0.35)), Color(1, 1, 1, 0.12))
	for sx in [0.14, 0.86]:
		_nut(Vector2(pr.position.x + pr.size.x * sx, pr.get_center().y), maxf(pr.size.y * 0.22, 4.0), Color("#c7ccd2"))
	var has_data := false
	for p in (d["ports"] as Array):
		if str(p["handle"]) == "data":
			has_data = true
	if has_data:
		var sb := Rect2(pr.get_center().x - pr.size.x * 0.08, pr.end.y - pr.size.y * 0.18, pr.size.x * 0.16, pr.size.y * 0.22)
		_rrect(sb, 1.0, Color("#1f6f4a"))
	if scale_px * 3.0 > 2.6:
		draw_string(font, Vector2(pr.position.x, pr.position.y - 5.0), name, HORIZONTAL_ALIGNMENT_CENTER, pr.size.x, _fs(3.0, 8, 12), INK)


func _draw_monitor(pr: Rect2, name: String, cap: String, font: Font, bold: Font) -> void:
	# A round panel gauge (a BMV): bezel, dark screen with a reading, its name under it.
	_shadow(pr, pr.size.x * 0.5)
	var c := Vector2(pr.get_center().x, pr.position.y + pr.size.y * 0.42)
	var rad := minf(pr.size.x, pr.size.y * 0.84) * 0.5
	draw_circle(c, rad, Color("#1a1f26"), true, -1.0, true)
	draw_circle(c, rad * 0.88, Color("#2b3340"), true, -1.0, true)
	var scr := Rect2(c.x - rad * 0.55, c.y - rad * 0.36, rad * 1.1, rad * 0.72)
	_rrect(scr, 2.0, Color("#102033"))
	if scale_px * 3.0 > 2.6:
		var fs := _fs(3.6, 8, 14)
		draw_string(bold, Vector2(scr.position.x, scr.get_center().y + fs * 0.36), "100 %", HORIZONTAL_ALIGNMENT_CENTER, scr.size.x, fs, Color("#9fd3ff"))
		draw_string(bold, Vector2(pr.position.x, pr.end.y - 4.0), name, HORIZONTAL_ALIGNMENT_CENTER, pr.size.x, maxi(fs - 2, 8), INK)
		if cap != "":
			draw_string(font, Vector2(pr.position.x, pr.end.y + fs - 2.0), cap, HORIZONTAL_ALIGNMENT_CENTER, pr.size.x, maxi(fs - 3, 8), INK_SOFT)


# ---------------------------------------------------------------------------
# Wires
# ---------------------------------------------------------------------------

func _cable_px(mm2: float, data: bool) -> float:
	if data:
		return clampf(scale_px * 1.4, 1.5, 4.0)
	return clampf(scale_px * (2.2 + 1.1 * sqrt(maxf(mm2, 0.5))), 2.2, 16.0)


func _draw_wire(cd: Dictionary, bold: Font) -> void:
	var wire: PackedVector2Array = cd["pts"]
	if wire.size() < 2:
		return
	var data := str(cd.get("polarity", "")) == "data"
	var smooth := WireSheet.fillet(wire, FILLET_MM)
	var pts := PackedVector2Array()
	for p in smooth:
		pts.append(to_px(p))
	var col: Color = cd["color"]
	var hot := str(cd["id"]) == conductor
	var w := _cable_px(float(cd.get("mm2", 0.0)), data)
	if hot:
		draw_polyline(pts, Color(SEL.r, SEL.g, SEL.b, 0.45), w + 10.0, true)
	if data:
		# A thin signal lead, dashed.
		draw_polyline(pts, Color(1, 1, 1, 0.9), w + 2.0, true)
		for i in range(1, pts.size()):
			draw_dashed_line(pts[i - 1], pts[i], col, w, maxf(w * 3.0, 6.0), true, true)
	else:
		# Jacket: a dark edge, the colour, a highlight along the top-left of the cable.
		draw_polyline(pts, col.darkened(0.55), w + 2.6, true)
		draw_polyline(pts, col, w, true)
		var hl := Color(1, 1, 1, 0.16 if col.get_luminance() < 0.3 else 0.28)
		var shifted := PackedVector2Array()
		for p2 in pts:
			shifted.append(p2 + Vector2(-w * 0.18, -w * 0.18))
		draw_polyline(shifted, hl, maxf(w * 0.28, 1.0), true)
	# Terminal lugs where a power cable lands.
	if not data and scale_px > 0.5:
		for e in [pts[0], pts[pts.size() - 1]]:
			draw_circle(e, w * 0.75 + 1.0, col.darkened(0.55), true, -1.0, true)
			draw_circle(e, w * 0.55, BRASS, true, -1.0, true)
	_gauge_chip(cd, wire, bold, col, data)


func _gauge_chip(cd: Dictionary, wire: PackedVector2Array, bold: Font, col: Color, data: bool) -> void:
	var label := str(cd.get("label", ""))
	if label == "" or scale_px < 0.3:
		return
	var anchor := WireSheet.label_anchor(wire)
	# A jumper between two parts in one lane has no room for a chip.
	if float(anchor.get("length", 0.0)) < 48.0 and str(cd["id"]) != conductor:
		return
	var mid := to_px(anchor["pos"])
	var text := "%s  ·  %.1f m" % [label, float(cd.get("length_m", 0.0))]
	if not data and float(cd.get("amps", 0.0)) > 0.0:
		text = "%s  ·  %.1f m  ·  %s A" % [label, float(cd.get("length_m", 0.0)), _num(float(cd["amps"]))]
	var fs := _fs(2.9, 9, 13)
	var tw := bold.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var chip_w := tw + 12.0
	var chip_h := fs + 7.0
	var w := _cable_px(float(cd.get("mm2", 0.0)), data)
	var chip: Rect2
	if bool(anchor["horizontal"]):
		chip = Rect2(mid + Vector2(-chip_w * 0.5, -w * 0.5 - chip_h - 4.0), Vector2(chip_w, chip_h))
	else:
		chip = Rect2(mid + Vector2(w * 0.5 + 6.0, -chip_h * 0.5), Vector2(chip_w, chip_h))
	_rrect(chip, 3.0, Color(1, 1, 1, 0.96))
	draw_rect(Rect2(chip.position, Vector2(3.0, chip.size.y)), col)
	draw_rect(chip, Color(0.72, 0.76, 0.8), false, 1.0)
	draw_string(bold, Vector2(chip.position.x + 8.0, chip.end.y - 4.5), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, INK)
	if bool(cd.get("upsized", false)) and not data:
		draw_circle(Vector2(chip.end.x - 1.0, chip.position.y + 1.0), 3.5, Color("#2e8b57"), true, -1.0, true)


static func _num(v: float) -> String:
	return str(int(round(v))) if absf(v - round(v)) < 0.05 else "%.1f" % v


func _box(id: String) -> Rect2:
	for d in (lay.get("devices", []) as Array):
		if str(d["id"]) == id:
			return d["box"]
	return Rect2()


# ---------------------------------------------------------------------------
# The page
# ---------------------------------------------------------------------------

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), PAPER)
	if lay.is_empty():
		return
	var font := UITheme.font("medium")
	var bold := UITheme.font("semibold")
	_draw_grid()
	# Data leads under the power cables, power cables under the gear.
	var power: Array = []
	for c in (lay.get("conductors", []) as Array):
		if str((c as Dictionary).get("polarity", "")) == "data":
			_draw_wire(c, bold)
		else:
			power.append(c)
	for c2 in power:
		_draw_wire(c2, bold)
	for d in (lay.get("devices", []) as Array):
		_draw_device(d, font, bold)
	_draw_checks(font, bold)


func _draw_grid() -> void:
	var step := 50.0 * scale_px
	if step < 14.0:
		return
	var o := Vector2(fposmod(origin.x, step), fposmod(origin.y, step))
	var x := o.x
	while x < size.x:
		draw_line(Vector2(x, 0), Vector2(x, size.y), GRID, 1.0)
		x += step
	var y := o.y
	while y < size.y:
		draw_line(Vector2(0, y), Vector2(size.x, y), GRID, 1.0)
		y += step


func _draw_checks(font: Font, bold: Font) -> void:
	var checks: Array = lay.get("checks", [])
	if checks.is_empty():
		return
	var b := WireSheet.ink_bounds(lay)
	var at := to_px(Vector2(b.position.x, b.position.y)) + Vector2(0, 14.0)
	var fs := clampi(int(scale_px * 3.2), 10, 14)
	for ck in checks:
		var lv := str(ck.get("level", "warn"))
		var cc := Color("#9a3412") if lv == "warn" else (Color("#b91c1c") if lv == "error" else Color("#334155"))
		var bar := Color("#f59e0b") if lv == "warn" else (Color("#dc2626") if lv == "error" else Color("#64748b"))
		var text := str(ck["text"])
		var tw := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var card := Rect2(at, Vector2(tw + 22.0, fs + 12.0))
		_rrect(card, 3.0, Color("#fff7ed") if lv == "warn" else (Color("#fef2f2") if lv == "error" else Color("#f1f5f9")))
		draw_rect(Rect2(card.position, Vector2(3.0, card.size.y)), bar)
		draw_rect(card, Color(bar.r, bar.g, bar.b, 0.35), false, 1.0)
		draw_string(font, Vector2(card.position.x + 12.0, card.end.y - 7.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, cc)
		at.y += card.size.y + 6.0
