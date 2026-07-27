class_name MudPlanCanvas
extends Control

## 2D bed sketch pad for mud building plans (bed mm, origin at center).
## Phase D: open wall runs, bezier freeform, select/move/delete.

signal plan_changed

enum Tool { RECT, ROUNDED_RECT, POLYLINE, SELECT, OPEN_POLYLINE, BEZIER }

var tool: Tool = Tool.RECT
var work_x_mm: float = 3048.0
var work_y_mm: float = 3048.0
var nozzle_mm: float = 76.2
var corner_r_mm: float = 200.0
var loops: Array = []  # closed
var open_paths: Array = []  # open runs
var selected_kind: String = "loop"  # "loop" | "open"
var selected_index: int = -1

var _drag_a := Vector2.ZERO
var _drag_b := Vector2.ZERO
var _dragging := false
var _poly_draft: PackedVector2Array = PackedVector2Array()
var _bezier_anchors: PackedVector2Array = PackedVector2Array()
var _moving := false
var _move_origin_mm := Vector2.ZERO
var _move_start: PackedVector2Array = PackedVector2Array()


func set_work(w: float, h: float, nozzle: float) -> void:
	work_x_mm = maxf(w, 100.0)
	work_y_mm = maxf(h, 100.0)
	nozzle_mm = maxf(nozzle, 1.0)
	queue_redraw()


func clear_loops() -> void:
	loops.clear()
	open_paths.clear()
	selected_index = -1
	_poly_draft = PackedVector2Array()
	_bezier_anchors = PackedVector2Array()
	_dragging = false
	_moving = false
	queue_redraw()
	plan_changed.emit()


func undo_last() -> void:
	if not _bezier_anchors.is_empty():
		_bezier_anchors.remove_at(_bezier_anchors.size() - 1)
		queue_redraw()
		return
	if not _poly_draft.is_empty():
		_poly_draft.remove_at(_poly_draft.size() - 1)
		queue_redraw()
		return
	if selected_kind == "open" and not open_paths.is_empty():
		if selected_index >= 0 and selected_index < open_paths.size():
			open_paths.remove_at(selected_index)
		else:
			open_paths.pop_back()
		selected_index = mini(selected_index, open_paths.size() - 1)
		plan_changed.emit()
		queue_redraw()
		return
	if loops.is_empty():
		return
	loops.pop_back()
	if selected_index >= loops.size():
		selected_index = loops.size() - 1
	queue_redraw()
	plan_changed.emit()


func delete_selected() -> bool:
	if selected_index < 0:
		return false
	if selected_kind == "open":
		if selected_index >= open_paths.size():
			return false
		open_paths.remove_at(selected_index)
		selected_index = mini(selected_index, open_paths.size() - 1)
	else:
		if selected_index >= loops.size():
			return false
		loops.remove_at(selected_index)
		selected_index = mini(selected_index, loops.size() - 1)
	queue_redraw()
	plan_changed.emit()
	return true


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	focus_mode = Control.FOCUS_ALL


func _draw() -> void:
	var r := get_rect().size
	draw_rect(Rect2(Vector2.ZERO, r), Color(0.08, 0.10, 0.14, 1.0))
	var bed := _bed_screen_rect()
	draw_rect(bed, Color(0.16, 0.18, 0.22, 1.0))
	draw_rect(bed, Color(0.35, 0.55, 0.65, 0.9), false, 2.0)
	var g := maxf(nozzle_mm, 50.0)
	var col := Color(1, 1, 1, 0.06)
	var x0 := -work_x_mm * 0.5
	var y0 := -work_y_mm * 0.5
	var xi := ceilf(x0 / g) * g
	while xi <= work_x_mm * 0.5:
		draw_line(_mm_to_screen(Vector2(xi, -work_y_mm * 0.5)),
			_mm_to_screen(Vector2(xi, work_y_mm * 0.5)), col, 1.0)
		xi += g
	var yi := ceilf(y0 / g) * g
	while yi <= work_y_mm * 0.5:
		draw_line(_mm_to_screen(Vector2(-work_x_mm * 0.5, yi)),
			_mm_to_screen(Vector2(work_x_mm * 0.5, yi)), col, 1.0)
		yi += g
	var o := _mm_to_screen(Vector2.ZERO)
	draw_line(o + Vector2(-8, 0), o + Vector2(8, 0), Color(0.5, 0.7, 0.8, 0.5), 1.0)
	draw_line(o + Vector2(0, -8), o + Vector2(0, 8), Color(0.5, 0.7, 0.8, 0.5), 1.0)
	for i in loops.size():
		var c := Color(0.35, 0.95, 0.75, 1.0) if selected_kind == "loop" and i == selected_index \
			else Color(0.85, 0.55, 0.25, 1.0)
		_draw_loop(loops[i] as PackedVector2Array, c, 3.5 if selected_kind == "loop" and i == selected_index else 2.5)
	for i in open_paths.size():
		var c2 := Color(0.55, 0.85, 1.0, 1.0) if selected_kind == "open" and i == selected_index \
			else Color(0.45, 0.7, 0.95, 0.95)
		_draw_open(open_paths[i] as PackedVector2Array, c2,
			3.5 if selected_kind == "open" and i == selected_index else 2.5)
	if _dragging and tool != Tool.POLYLINE and tool != Tool.SELECT \
			and tool != Tool.OPEN_POLYLINE and tool != Tool.BEZIER:
		var live := _live_shape()
		if live.size() >= 3:
			_draw_loop(live, Color(0.4, 0.9, 1.0, 0.9), 2.0)
	if (tool == Tool.POLYLINE or tool == Tool.OPEN_POLYLINE) and _poly_draft.size() > 0:
		_draw_open(_poly_draft, Color(0.4, 0.9, 1.0, 0.9), 2.0)
	if tool == Tool.BEZIER and _bezier_anchors.size() > 0:
		_draw_bezier_draft()


func _draw_loop(pts: PackedVector2Array, color: Color, width: float) -> void:
	var closed := MudPlanOps.close_loop(pts)
	for i in range(1, closed.size()):
		draw_line(_mm_to_screen(closed[i - 1]), _mm_to_screen(closed[i]), color, width)
	for p: Vector2 in MudPlanOps.open_ring(pts):
		draw_circle(_mm_to_screen(p), 3.5, color)


func _draw_open(pts: PackedVector2Array, color: Color, width: float) -> void:
	for i in range(1, pts.size()):
		draw_line(_mm_to_screen(pts[i - 1]), _mm_to_screen(pts[i]), color, width)
	for p: Vector2 in pts:
		draw_circle(_mm_to_screen(p), 3.5, color)


func _draw_bezier_draft() -> void:
	for p: Vector2 in _bezier_anchors:
		draw_circle(_mm_to_screen(p), 4.5, Color(0.95, 0.75, 0.35, 1.0))
	for i in range(1, _bezier_anchors.size()):
		draw_line(_mm_to_screen(_bezier_anchors[i - 1]), _mm_to_screen(_bezier_anchors[i]),
			Color(0.95, 0.75, 0.35, 0.45), 1.5)
	if _bezier_anchors.size() >= 2:
		var preview := MudBuildingSpec.make_bezier_chain(_bezier_anchors, false, 6)
		_draw_open(preview, Color(0.4, 0.9, 1.0, 0.85), 2.0)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_on_lmb_down(mb.position)
			else:
				_on_lmb_up(mb.position)
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			if tool == Tool.POLYLINE and _poly_draft.size() >= 3:
				_commit_polyline(true)
			elif tool == Tool.OPEN_POLYLINE and _poly_draft.size() >= 2:
				_commit_polyline(false)
			elif tool == Tool.BEZIER and _bezier_anchors.size() >= 2:
				_commit_bezier(false)
			accept_event()
	elif event is InputEventMouseMotion:
		var mm := (event as InputEventMouseMotion)
		if _moving and tool == Tool.SELECT and selected_index >= 0:
			_apply_move(_snap(_screen_to_mm(mm.position)))
			accept_event()
		elif _dragging:
			_drag_b = _snap(_screen_to_mm(mm.position))
			queue_redraw()
			accept_event()
	elif event is InputEventKey and event.pressed:
		var ke := event as InputEventKey
		if ke.keycode == KEY_ENTER or ke.keycode == KEY_KP_ENTER:
			if tool == Tool.POLYLINE and _poly_draft.size() >= 3:
				_commit_polyline(true)
				accept_event()
			elif tool == Tool.OPEN_POLYLINE and _poly_draft.size() >= 2:
				_commit_polyline(false)
				accept_event()
			elif tool == Tool.BEZIER and _bezier_anchors.size() >= 2:
				# Shift+Enter closes as room; Enter keeps open wall.
				_commit_bezier(ke.shift_pressed)
				accept_event()
		elif ke.keycode == KEY_ESCAPE:
			_poly_draft = PackedVector2Array()
			_bezier_anchors = PackedVector2Array()
			_dragging = false
			_moving = false
			selected_index = -1
			queue_redraw()
			accept_event()
		elif ke.keycode == KEY_DELETE or ke.keycode == KEY_BACKSPACE:
			if delete_selected():
				accept_event()


func _on_lmb_down(screen_pos: Vector2) -> void:
	var mm := _snap(_screen_to_mm(screen_pos))
	if tool == Tool.SELECT:
		grab_focus()
		_hit_select(mm)
		if selected_index >= 0:
			_moving = true
			_move_origin_mm = mm
			if selected_kind == "open":
				_move_start = (open_paths[selected_index] as PackedVector2Array).duplicate()
			else:
				_move_start = (loops[selected_index] as PackedVector2Array).duplicate()
		queue_redraw()
		return
	if tool == Tool.POLYLINE or tool == Tool.OPEN_POLYLINE:
		_poly_draft.append(mm)
		queue_redraw()
		return
	if tool == Tool.BEZIER:
		_bezier_anchors.append(mm)
		queue_redraw()
		return
	_dragging = true
	_drag_a = mm
	_drag_b = mm
	queue_redraw()


func _on_lmb_up(screen_pos: Vector2) -> void:
	if tool == Tool.SELECT:
		if _moving and selected_index >= 0:
			_apply_move(_snap(_screen_to_mm(screen_pos)))
			_moving = false
			plan_changed.emit()
		queue_redraw()
		return
	if tool == Tool.POLYLINE or tool == Tool.OPEN_POLYLINE or tool == Tool.BEZIER:
		return
	if not _dragging:
		return
	_dragging = false
	_drag_b = _snap(_screen_to_mm(screen_pos))
	var live := _live_shape()
	var v := MudPlanOps.validate_loop(live, nozzle_mm, work_x_mm, work_y_mm)
	if bool(v.get("ok", false)):
		loops.append(v.get("cleaned", PackedVector2Array()))
		selected_kind = "loop"
		selected_index = loops.size() - 1
		plan_changed.emit()
	queue_redraw()


func _apply_move(mm: Vector2) -> void:
	if selected_index < 0:
		return
	var delta := mm - _move_origin_mm
	var moved := PackedVector2Array()
	for p: Vector2 in _move_start:
		moved.append(p + delta)
	if selected_kind == "open":
		var v := MudPlanOps.validate_open_path(moved, nozzle_mm, work_x_mm, work_y_mm)
		open_paths[selected_index] = v.get("cleaned", moved) if bool(v.get("ok", false)) else moved
	else:
		var v2 := MudPlanOps.validate_loop(moved, nozzle_mm, work_x_mm, work_y_mm)
		loops[selected_index] = v2.get("cleaned", moved) if bool(v2.get("ok", false)) else moved
	queue_redraw()


func _hit_select(mm: Vector2) -> void:
	selected_index = -1
	selected_kind = "loop"
	var tol := maxf(nozzle_mm * 1.5, 80.0)
	# Prefer open paths near cursor, then closed.
	var best_d := INF
	for i in open_paths.size():
		var d := _dist_to_path(mm, open_paths[i] as PackedVector2Array)
		if d < tol and d < best_d:
			best_d = d
			selected_index = i
			selected_kind = "open"
	for i in loops.size():
		var ring: PackedVector2Array = MudPlanOps.open_ring(loops[i] as PackedVector2Array)
		if ring.size() >= 3 and Geometry2D.is_point_in_polygon(mm, ring):
			selected_index = i
			selected_kind = "loop"
			return
		for j in ring.size():
			var d2 := _dist_point_segment(mm, ring[j], ring[(j + 1) % ring.size()])
			if d2 < tol and d2 < best_d:
				best_d = d2
				selected_index = i
				selected_kind = "loop"


func _dist_to_path(mm: Vector2, path: PackedVector2Array) -> float:
	var best := INF
	for i in range(1, path.size()):
		best = minf(best, _dist_point_segment(mm, path[i - 1], path[i]))
	return best


func _dist_point_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var t := 0.0 if ab.length_squared() < 1e-9 else clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
	return p.distance_to(a + ab * t)


func _commit_polyline(closed: bool) -> void:
	if closed:
		var v := MudPlanOps.validate_loop(_poly_draft, nozzle_mm, work_x_mm, work_y_mm)
		_poly_draft = PackedVector2Array()
		if bool(v.get("ok", false)):
			loops.append(v.get("cleaned", PackedVector2Array()))
			selected_kind = "loop"
			selected_index = loops.size() - 1
			plan_changed.emit()
	else:
		var vo := MudPlanOps.validate_open_path(_poly_draft, nozzle_mm, work_x_mm, work_y_mm)
		_poly_draft = PackedVector2Array()
		if bool(vo.get("ok", false)):
			open_paths.append(vo.get("cleaned", PackedVector2Array()))
			selected_kind = "open"
			selected_index = open_paths.size() - 1
			plan_changed.emit()
	queue_redraw()


func _commit_bezier(closed: bool) -> void:
	var chain := MudBuildingSpec.make_bezier_chain(_bezier_anchors, closed, 8)
	_bezier_anchors = PackedVector2Array()
	if closed:
		var v := MudPlanOps.validate_loop(chain, nozzle_mm, work_x_mm, work_y_mm)
		if bool(v.get("ok", false)):
			loops.append(v.get("cleaned", PackedVector2Array()))
			selected_kind = "loop"
			selected_index = loops.size() - 1
			plan_changed.emit()
	else:
		var vo := MudPlanOps.validate_open_path(chain, nozzle_mm, work_x_mm, work_y_mm)
		if bool(vo.get("ok", false)):
			open_paths.append(vo.get("cleaned", PackedVector2Array()))
			selected_kind = "open"
			selected_index = open_paths.size() - 1
			plan_changed.emit()
	queue_redraw()


func _live_shape() -> PackedVector2Array:
	var c := (_drag_a + _drag_b) * 0.5
	var w := absf(_drag_b.x - _drag_a.x)
	var h := absf(_drag_b.y - _drag_a.y)
	w = maxf(w, nozzle_mm * 2.0)
	h = maxf(h, nozzle_mm * 2.0)
	if tool == Tool.ROUNDED_RECT:
		return MudBuildingSpec.make_rounded_rect(c.x, c.y, w, h, corner_r_mm)
	return MudBuildingSpec.make_rect(c.x, c.y, w, h)


func _bed_screen_rect() -> Rect2:
	var tl := _mm_to_screen(Vector2(-work_x_mm * 0.5, work_y_mm * 0.5))
	var br := _mm_to_screen(Vector2(work_x_mm * 0.5, -work_y_mm * 0.5))
	return Rect2(tl, br - tl).abs()


func _mm_to_screen(mm: Vector2) -> Vector2:
	var r := size
	if r.x < 2.0 or r.y < 2.0:
		return Vector2.ZERO
	var margin := 16.0
	var s := minf((r.x - margin * 2.0) / work_x_mm, (r.y - margin * 2.0) / work_y_mm)
	return Vector2(r.x * 0.5 + mm.x * s, r.y * 0.5 - mm.y * s)


func _screen_to_mm(screen: Vector2) -> Vector2:
	var r := size
	var margin := 16.0
	var s := minf((r.x - margin * 2.0) / work_x_mm, (r.y - margin * 2.0) / work_y_mm)
	return Vector2((screen.x - r.x * 0.5) / s, -(screen.y - r.y * 0.5) / s)


func _snap(mm: Vector2) -> Vector2:
	var g := maxf(nozzle_mm, 1.0)
	return Vector2(roundf(mm.x / g) * g, roundf(mm.y / g) * g)
