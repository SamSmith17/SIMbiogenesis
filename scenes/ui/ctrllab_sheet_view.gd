extends Control

## The Controller Lab's Terminals view (Phase 3): one face of the unit seen
## straight on, drawn from CtrlSheet.layout (the same data the SVG export
## draws). Wheel zooms about the pointer, a drag on empty paper pans, a press
## on a connector selects it and a drag moves it, a click with a connector
## armed places it.

signal port_selected(id: String)
signal port_moved(id: String, delta: Vector2)
signal place_requested(face: String, u: float, v: float)

const FACE_DRAW := preload("res://scenes/ui/kit/ctrl_face_draw.gd")
const BG := Color(0.07, 0.08, 0.1)
const PAPER := Color(0.16, 0.17, 0.2)
const EDGE := Color(0.62, 0.65, 0.7)
const SEL := Color(1.0, 0.78, 0.2)

var lay: Dictionary = {}
var selected := ""
var show_wires := true
var tool := ""                ## connector armed for placing ("" = none)
var scale_px := 2.0           ## pixels per mm
var origin := Vector2.ZERO    ## where face (0, 0) is drawn
var _fitted_key := ""
var _press := {}
var _drag_delta := Vector2.ZERO
var _hover := Vector2.INF


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	resized.connect(_on_resized)


func _on_resized() -> void:
	if not lay.is_empty():
		fit()


func set_layout(l: Dictionary, sel: String) -> void:
	lay = l
	selected = sel
	var key := "%s|%s" % [str(l.get("face", "")), str(l.get("size", ""))]
	if key != _fitted_key:
		_fitted_key = key
		fit()
	queue_redraw()


func fit() -> void:
	if lay.is_empty() or size.x < 10.0 or size.y < 10.0:
		return
	var b: Rect2 = lay["bounds"]
	scale_px = minf(size.x / b.size.x, size.y / b.size.y) * 0.92
	var c := b.get_center()
	origin = size * 0.5 - Vector2(c.x, -c.y) * scale_px
	queue_redraw()


## Face mm → this control's pixels, and back.
func to_px(q: Vector2) -> Vector2:
	return origin + Vector2(q.x, -q.y) * scale_px


func to_face(px: Vector2) -> Vector2:
	var d := (px - origin) / scale_px
	return Vector2(d.x, -d.y)


## Where a face point is on the screen (what a harness clicks).
func screen_of(q: Vector2) -> Vector2:
	return get_global_transform() * to_px(q)


func port_layout(id: String) -> Dictionary:
	for p in (lay.get("ports", []) as Array):
		if str(p["id"]) == id:
			return p
	return {}


func _gui_input(e: InputEvent) -> void:
	if lay.is_empty():
		return
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			var k := 1.12 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.12
			var before := to_face(mb.position)
			scale_px = clampf(scale_px * k, 0.2, 60.0)
			origin += mb.position - to_px(before)
			queue_redraw()
			accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			var q := to_face(mb.position)
			if tool != "":
				var tgt := _place_target(q)
				place_requested.emit(str(tgt["face"]), float(tgt["u"]), float(tgt["v"]))
				accept_event()
				return
			var hit := CtrlSheet.port_at(lay, q)
			_press = {"pos": mb.position, "port": hit, "moved": false}
			_drag_delta = Vector2.ZERO
			if hit != "":
				selected = hit
				port_selected.emit(hit)
			queue_redraw()
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed and not _press.is_empty():
			var id := str(_press["port"])
			var moved := bool(_press["moved"])
			_press = {}
			if id != "" and moved and _drag_delta.length() > 0.2:
				port_moved.emit(id, Vector2(snappedf(_drag_delta.x, 0.5), snappedf(_drag_delta.y, 0.5)))
			elif id == "" and not moved:
				selected = ""
				port_selected.emit("")
			_drag_delta = Vector2.ZERO
			queue_redraw()
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_MIDDLE:
			_press = {"pos": mb.position, "port": "", "moved": false} if mb.pressed else {}
			accept_event()
	elif e is InputEventMouseMotion:
		var mm := e as InputEventMouseMotion
		_hover = mm.position
		if not _press.is_empty():
			if (mm.position - (_press["pos"] as Vector2)).length() > 3.0:
				_press["moved"] = true
			if bool(_press["moved"]):
				if str(_press["port"]) != "":
					_drag_delta = (mm.position - (_press["pos"] as Vector2)) / scale_px * Vector2(1, -1)
				else:
					origin += mm.relative
			accept_event()
		queue_redraw()


## A front point inside the wiring bay lands on the bay's back plate.
func _place_target(q: Vector2) -> Dictionary:
	if bool(lay.get("has_bay", false)) and (lay["bay"] as Rect2).has_point(q):
		var br: Rect2 = lay["bay"]
		return {"face": "bay", "u": q.x - br.get_center().x, "v": q.y - br.get_center().y}
	return {"face": str(lay["face"]), "u": q.x, "v": q.y}


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), BG)
	if lay.is_empty():
		return
	var fbold := UITheme.font("semibold")
	var r: Rect2 = lay["rect"]
	var pr := Rect2(to_px(Vector2(r.position.x, r.end.y)), r.size * scale_px)
	var head := "%s  ·  %s × %s mm" % [str(CtrlSheet.FACE_WORDS.get(lay["face"], lay["face"])),
		_n(r.size.x), _n(r.size.y)]
	draw_string(fbold, pr.position + Vector2(0, -8), head, HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_SM, EDGE)
	# The unit as it looks, its connectors, pins and leads: the shared face
	# drawer, so this view and the wiring page agree.
	var drag_port := str(_press.get("port", "#"))
	FACE_DRAW.draw(self, lay, Callable(self, "to_px"), scale_px, {
		"selected": selected, "drag": drag_port if _drag_delta != Vector2.ZERO else "", "drag_mm": _drag_delta,
		"leads": show_wires, "lead_labels": true, "dark": true,
	})
	if bool(lay["has_bay"]):
		var br: Rect2 = lay["bay"]
		var bpr := Rect2(to_px(Vector2(br.position.x, br.end.y)), br.size * scale_px)
		_dashed_rect(bpr, Color(0.5, 0.53, 0.58))
		draw_string(UITheme.font("medium"), Vector2(bpr.position.x + 4, bpr.end.y - 6), "Wiring bay", HORIZONTAL_ALIGNMENT_LEFT, -1,
			UITheme.FONT_XS, Color(0.7, 0.73, 0.78))
	if tool != "" and _hover != Vector2.INF:
		draw_circle(_hover, 6.0, Color(0.35, 0.85, 1.0, 0.8), false, 2.0, true)
		draw_string(UITheme.font("medium"), _hover + Vector2(10, -8), ConnectorCatalog.label(tool), HORIZONTAL_ALIGNMENT_LEFT, -1,
			UITheme.FONT_XS, Color(0.35, 0.85, 1.0))


func _dashed_rect(r: Rect2, c: Color) -> void:
	var pts := [r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y), r.position]
	for i in 4:
		draw_dashed_line(pts[i], pts[i + 1], c, 1.0, 6.0)


static func _n(v: float) -> String:
	return str(int(round(v))) if absf(v - round(v)) < 0.05 else "%.1f" % v
