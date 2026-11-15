class_name GreenhousePlanView
extends Control

## The greenhouse designer's Plan tab: the floor from above with its beds,
## keyholes, barrels and doors. Click a bed to select it, drag it to move it,
## drag on an empty part of the floor to draw a new bed. Every change goes
## through the modal (one undo step each).

const MARGIN := 40.0
const SNAP_M := 0.05
const DRAW_MIN_M := 0.4

var modal: Node = null

var _drag_id := ""
var _drag_from := Vector2.ZERO
var _drag_off := Vector2.ZERO
var _drag_pos := Vector2.INF
var _draw_from := Vector2.INF
var _draw_to := Vector2.INF


## A colour per crop (the leaf colour of its kind, roughly).
static func crop_color(id: String) -> Color:
	var h := float(GardenCrops.info(id)["height"])
	var i := GardenCrops.CROPS.keys().find(id)
	var hue := 0.22 + 0.12 * fposmod(float(i) * 0.618034, 1.0)
	return Color.from_hsv(hue, 0.55, clampf(0.45 + h * 0.12, 0.45, 0.75))


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_CLICK


func _design() -> Dictionary:
	return modal.call("design") if modal != null else {}


## Metres (x along the length, z across) per pixel and the origin on screen.
func _xf() -> Dictionary:
	var d := _design()
	if d.is_empty():
		return {"s": 1.0, "o": size * 0.5}
	var s: Dictionary = d["spec"]
	var L := float(s["length_m"])
	var W := float(s["width_m"])
	var sc := minf((size.x - 2.0 * MARGIN) / maxf(L, 0.1), (size.y - 2.0 * MARGIN) / maxf(W, 0.1))
	return {"s": maxf(sc, 0.5), "o": size * 0.5}


func to_screen(p: Vector2) -> Vector2:
	var t := _xf()
	return Vector2(t["o"]) + p * float(t["s"])


func to_floor(sp: Vector2) -> Vector2:
	var t := _xf()
	return (sp - Vector2(t["o"])) / float(t["s"])


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), UITheme.C_BG)
	var d := _design()
	if d.is_empty():
		return
	var fr: Dictionary = d["frame"]
	var s: Dictionary = d["spec"]
	var sc := float(_xf()["s"])
	# The floor.
	if str(fr["floor"]["kind"]) == "circle":
		var r := float(fr["floor"]["r"])
		draw_circle(to_screen(Vector2.ZERO), r * sc, Color(0.32, 0.29, 0.25))
		draw_arc(to_screen(Vector2.ZERO), r * sc, 0.0, TAU, 96, Color(0.75, 0.86, 0.95), 2.0, true)
	else:
		var hl := float(s["length_m"]) * 0.5
		var hw := float(s["width_m"]) * 0.5
		var rc := Rect2(to_screen(Vector2(-hl, -hw)), Vector2(hl * 2.0, hw * 2.0) * sc)
		draw_rect(rc, Color(0.32, 0.29, 0.25))
		draw_rect(rc, Color(0.75, 0.86, 0.95), false, 2.0)
		if str(fr["form"]) == "lean_to":
			draw_line(rc.position, Vector2(rc.end.x, rc.position.y), Color(0.7, 0.55, 0.42), 6.0)
	# Doors.
	for dr in fr["doors"]:
		var dd: Dictionary = dr
		var c := to_screen(Vector2(float(dd["x"]), float(dd["z"])))
		var n: Vector3 = dd["normal"]
		var along := Vector2(-n.z, n.x).normalized() * float(dd["w_m"]) * 0.5 * sc
		draw_line(c - along, c + along, UITheme.C_AMBER, 5.0)
	# Barrels.
	for p in d["barrels"]["positions"]:
		draw_circle(to_screen(p as Vector2), GreenhouseBeds.BARREL_D * 0.5 * sc, Color(0.1, 0.1, 0.12))
	# Beds.
	var sel := str(modal.call("selected_bed")) if modal != null else ""
	var font := get_theme_default_font()
	for b in d["beds"]:
		var bd: Dictionary = b
		var c2 := Vector2(float(bd["x"]), float(bd["z"]))
		if str(bd["id"]) == _drag_id and _drag_pos != Vector2.INF:
			c2 = _drag_pos
		var crop := str(GreenhouseSpec.mix_crops(bd["crops"])[0])
		var fill := crop_color(crop)
		if str(bd["kind"]) == "keyhole":
			var k: Dictionary = bd["keyhole"]
			for r in GrowBed._keyhole_rings(k):
				var rr: Dictionary = r
				var mid := (float(rr["r0"]) + float(rr["r1"])) * 0.5
				var w := (float(rr["r1"]) - float(rr["r0"])) * sc
				# GrowBed's keyhole slot is centred on +Z; on screen +Z is down.
				draw_arc(to_screen(c2), mid * sc, float(rr["a0"]) + PI * 0.5, float(rr["a1"]) + PI * 0.5, 64, fill.darkened(0.15), w, true)
		else:
			var hl2 := float(bd["length_m"]) * 0.5
			var hw2 := float(bd["width_m"]) * 0.5
			var r2 := Rect2(to_screen(c2 - Vector2(hl2, hw2)), Vector2(hl2 * 2.0, hw2 * 2.0) * sc)
			draw_rect(r2, fill.darkened(0.2))
			if bool(bd.get("gantry", false)):
				draw_line(r2.position, Vector2(r2.end.x, r2.position.y), Color(0.85, 0.85, 0.9), 3.0)
				draw_line(Vector2(r2.position.x, r2.end.y), r2.end, Color(0.85, 0.85, 0.9), 3.0)
			if bool(bd.get("lights", false)):
				for i in 3:
					var yy := lerpf(r2.position.y, r2.end.y, (float(i) + 0.5) / 3.0)
					draw_line(Vector2(r2.position.x + 4, yy), Vector2(r2.end.x - 4, yy), Color(1.0, 0.55, 0.85, 0.8), 1.5)
			if str(bd["id"]) == sel:
				draw_rect(r2.grow(3.0), UITheme.C_PRIMARY, false, 2.5)
		if str(bd["kind"]) == "keyhole" and str(bd["id"]) == sel:
			draw_arc(to_screen(c2), float(bd["keyhole"]["outer_r"]) * sc + 4.0, 0.0, TAU, 96, UITheme.C_PRIMARY, 2.5, true)
		draw_string(font, to_screen(c2) + Vector2(-8, 5), str(bd["id"]), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1, 0.9))
	# A bed being drawn.
	if _draw_from != Vector2.INF and _draw_to != Vector2.INF:
		var a := to_screen(_draw_from)
		var b2 := to_screen(_draw_to)
		draw_rect(Rect2(a, b2 - a).abs(), Color(0.5, 0.8, 0.5, 0.35))
		draw_rect(Rect2(a, b2 - a).abs(), Color(0.6, 0.95, 0.6), false, 2.0)
	draw_string(font, Vector2(12, size.y - 12), "Click a bed to edit it · drag it to move · drag on the floor to draw a bed · Del removes",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 12, UITheme.C_TEXT_S)


func bed_at(sp: Vector2) -> String:
	var d := _design()
	if d.is_empty():
		return ""
	var p := to_floor(sp)
	for b in d["beds"]:
		var bd: Dictionary = b
		var c := Vector2(float(bd["x"]), float(bd["z"]))
		if str(bd["kind"]) == "keyhole":
			if p.distance_to(c) <= float(bd["keyhole"]["outer_r"]):
				return str(bd["id"])
		elif absf(p.x - c.x) <= float(bd["length_m"]) * 0.5 and absf(p.y - c.y) <= float(bd["width_m"]) * 0.5:
			return str(bd["id"])
	return ""


func _gui_input(e: InputEvent) -> void:
	if modal == null:
		return
	if e is InputEventMouseButton and (e as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var mb := e as InputEventMouseButton
		if mb.pressed:
			var id := bed_at(mb.position)
			if not id.is_empty():
				modal.call("select_bed", id)
				var bd: Dictionary = {}
				for b in _design()["beds"]:
					if str(b["id"]) == id:
						bd = b
				_drag_id = id
				_drag_from = to_floor(mb.position)
				_drag_off = Vector2(float(bd["x"]), float(bd["z"])) - _drag_from
				_drag_pos = Vector2.INF
			else:
				modal.call("select_bed", "")
				_draw_from = _snap(to_floor(mb.position))
				_draw_to = _draw_from
			accept_event()
		else:
			if not _drag_id.is_empty():
				if _drag_pos != Vector2.INF and _drag_pos.distance_to(_drag_from + _drag_off) > SNAP_M * 0.5:
					modal.call("move_bed", _drag_id, _drag_pos.x, _drag_pos.y)
				_drag_id = ""
				_drag_pos = Vector2.INF
			elif _draw_from != Vector2.INF:
				var r := Rect2(_draw_from, _draw_to - _draw_from).abs()
				if r.size.x >= DRAW_MIN_M and r.size.y >= DRAW_MIN_M * 0.75:
					modal.call("add_bed", r)
				_draw_from = Vector2.INF
				_draw_to = Vector2.INF
			queue_redraw()
			accept_event()
	elif e is InputEventMouseMotion:
		var mm := e as InputEventMouseMotion
		if not _drag_id.is_empty():
			_drag_pos = _snap(to_floor(mm.position) + _drag_off)
			queue_redraw()
		elif _draw_from != Vector2.INF:
			_draw_to = _snap(to_floor(mm.position))
			queue_redraw()


func _snap(p: Vector2) -> Vector2:
	return Vector2(snappedf(p.x, SNAP_M), snappedf(p.y, SNAP_M))
