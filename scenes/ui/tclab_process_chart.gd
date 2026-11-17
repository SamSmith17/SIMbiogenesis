extends Control

## TC Process Lab time chart: stacked lanes over one time axis (hours), a
## playhead, and the run computed so far shaded. Pure _draw over pushed data
## (`set_lanes`, `set_playhead`); a click or drag on it emits `scrubbed`.
## Lanes: [{label, unit, series: [{label, color, pts: PackedVector2Array
## (x = h, y = value)}], min (optional), max (optional)}].

signal scrubbed(t_h: float)

const C_BG := Color(0.05, 0.08, 0.13, 0.55)
const C_GRID := Color(0.35, 0.45, 0.60, 0.20)
const C_AXIS := Color(0.60, 0.72, 0.88, 0.65)
const C_TEXT := Color(0.72, 0.80, 0.92, 0.9)
const C_HEAD := Color(1.0, 0.82, 0.35, 1.0)
const C_DONE := Color(0.30, 0.55, 0.85, 0.08)
const MARGIN_L := 44.0
const MARGIN_R := 8.0
const MARGIN_T := 4.0
const MARGIN_B := 16.0
const LANE_GAP := 6.0

var _lanes: Array = []
var _t_end_h := 1.0
var _done_h := 0.0
var _head_h := 0.0
var _dragging := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(0, 240)


func set_lanes(lanes: Array, t_end_h: float, done_h: float) -> void:
	_lanes = lanes
	_t_end_h = maxf(t_end_h, 0.01)
	_done_h = done_h
	queue_redraw()


func set_playhead(t_h: float) -> void:
	if absf(t_h - _head_h) < 1e-4:
		return
	_head_h = t_h
	queue_redraw()


func _plot_rect() -> Rect2:
	return Rect2(MARGIN_L, MARGIN_T, maxf(size.x - MARGIN_L - MARGIN_R, 10.0), maxf(size.y - MARGIN_T - MARGIN_B, 10.0))


func _x_of(t_h: float, r: Rect2) -> float:
	return r.position.x + clampf(t_h / _t_end_h, 0.0, 1.0) * r.size.x


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and (e as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		_dragging = (e as InputEventMouseButton).pressed
		if _dragging:
			_emit_at((e as InputEventMouseButton).position.x)
		accept_event()
	elif e is InputEventMouseMotion and _dragging:
		_emit_at((e as InputEventMouseMotion).position.x)
		accept_event()


func _emit_at(x: float) -> void:
	var r := _plot_rect()
	var t := clampf((x - r.position.x) / r.size.x, 0.0, 1.0) * _t_end_h
	scrubbed.emit(t)


func _draw() -> void:
	var r := _plot_rect()
	draw_rect(Rect2(Vector2.ZERO, size), C_BG)
	var font := get_theme_default_font()
	var fs := UITheme.FONT_XS
	var n := maxi(_lanes.size(), 1)
	var lane_h := (r.size.y - LANE_GAP * float(n - 1)) / float(n)
	# The computed part of the run.
	draw_rect(Rect2(r.position, Vector2(_x_of(_done_h, r) - r.position.x, r.size.y)), C_DONE)
	# Hour grid.
	var step := 1.0 if _t_end_h <= 12.0 else 2.0
	if _t_end_h <= 2.0:
		step = 0.25
	var t := 0.0
	while t <= _t_end_h + 1e-6:
		var x := _x_of(t, r)
		draw_line(Vector2(x, r.position.y), Vector2(x, r.end.y), C_GRID, 1.0)
		draw_string(font, Vector2(x - 8.0, size.y - 3.0), ("%.0f h" % t) if step >= 1.0 else ("%d min" % int(round(t * 60.0))), HORIZONTAL_ALIGNMENT_LEFT, -1, fs, C_TEXT)
		t += step
	for li in _lanes.size():
		var lane: Dictionary = _lanes[li]
		var top := r.position.y + float(li) * (lane_h + LANE_GAP)
		var lr := Rect2(r.position.x, top, r.size.x, lane_h)
		draw_line(Vector2(lr.position.x, lr.end.y), lr.end, C_AXIS, 1.0)
		var lo := INF
		var hi := -INF
		for s in lane.get("series", []):
			for p in s["pts"]:
				lo = minf(lo, p.y)
				hi = maxf(hi, p.y)
		if lane.has("min"):
			lo = float(lane["min"])
		if lane.has("max"):
			hi = maxf(float(lane["max"]), hi)
		if not is_finite(lo) or not is_finite(hi):
			lo = 0.0
			hi = 1.0
		if hi - lo < 1e-6:
			hi = lo + 1.0
		draw_string(font, Vector2(2.0, top + fs), "%s" % str(lane.get("label", "")), HORIZONTAL_ALIGNMENT_LEFT, MARGIN_L - 4.0, fs, C_TEXT)
		draw_string(font, Vector2(2.0, top + fs * 2.2), _fmt(hi), HORIZONTAL_ALIGNMENT_LEFT, MARGIN_L - 4.0, fs, C_AXIS)
		draw_string(font, Vector2(2.0, lr.end.y - 2.0), _fmt(lo), HORIZONTAL_ALIGNMENT_LEFT, MARGIN_L - 4.0, fs, C_AXIS)
		var lx := lr.position.x + 4.0
		for s in lane.get("series", []):
			var pts: PackedVector2Array = s["pts"]
			var c: Color = s["color"]
			if pts.size() >= 2:
				var poly := PackedVector2Array()
				poly.resize(pts.size())
				for k in pts.size():
					var p := pts[k]
					poly[k] = Vector2(_x_of(p.x, lr), lr.end.y - (p.y - lo) / (hi - lo) * lr.size.y)
				draw_polyline(poly, c, 1.5, true)
			var label := str(s.get("label", ""))
			draw_string(font, Vector2(lx, top + fs), label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, c)
			lx += font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x + 10.0
		if lane.has("unit"):
			draw_string(font, Vector2(lr.end.x - 40.0, top + fs), str(lane["unit"]), HORIZONTAL_ALIGNMENT_RIGHT, 38.0, fs, C_AXIS)
	var hx := _x_of(_head_h, r)
	draw_line(Vector2(hx, r.position.y), Vector2(hx, r.end.y), C_HEAD, 2.0)


static func _fmt(v: float) -> String:
	if absf(v) >= 100.0:
		return "%.0f" % v
	if absf(v) >= 10.0:
		return "%.1f" % v
	return "%.2f" % v
