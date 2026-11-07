extends Control

## One entity, real board against twin, over the compared span: the twin's
## ideal reading in cyan, the real board's in amber, both drawn as held
## steps (a reading holds until the next), with the value range on the left
## and the span's ends below. Gaps (unavailable) break the line.

var _real: Array = []
var _twin: Array = []
var _t0 := 0.0
var _t1 := 1.0
var _unit := ""
var _font: Font


func _ready() -> void:
	custom_minimum_size = Vector2(0, 120)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = UITheme.font("regular")


func set_data(real: Array, twin: Array, t0: float, t1: float, unit: String) -> void:
	_real = real
	_twin = twin
	_t0 = t0
	_t1 = maxf(t1, t0 + 1e-6)
	_unit = unit
	queue_redraw()


func _range() -> Vector2:
	var lo := INF
	var hi := -INF
	for s in [_real, _twin]:
		for r in s:
			var v := float(r[1])
			if not is_nan(v):
				lo = minf(lo, v)
				hi = maxf(hi, v)
	if lo == INF:
		return Vector2(0, 1)
	if hi - lo < 1e-6:
		lo -= 0.5
		hi += 0.5
	var pad := (hi - lo) * 0.08
	return Vector2(lo - pad, hi + pad)


func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	draw_rect(r, Color(0.05, 0.07, 0.12))
	var plot := Rect2(Vector2(54, 8), size - Vector2(64, 26))
	if plot.size.x < 20.0 or plot.size.y < 20.0:
		return
	draw_rect(plot, Color(1, 1, 1, 0.04))
	var yr := _range()
	var fs := UITheme.FONT_XS
	for fv in [0.0, 0.5, 1.0]:
		var f := float(fv)
		var v := lerpf(yr.x, yr.y, f)
		var y := plot.end.y - f * plot.size.y
		draw_line(Vector2(plot.position.x, y), Vector2(plot.end.x, y), Color(1, 1, 1, 0.07), 1.0)
		draw_string(_font, Vector2(4, y + 4), "%s" % String.num(v, 2 if absf(yr.y - yr.x) < 10.0 else 0), HORIZONTAL_ALIGNMENT_LEFT, 48, fs, UITheme.C_TEXT_M)
	var span_h := _t1 - _t0
	draw_string(_font, Vector2(plot.position.x, size.y - 4), "%s ago" % UiText.duration(span_h), HORIZONTAL_ALIGNMENT_LEFT, -1, fs, UITheme.C_TEXT_M)
	draw_string(_font, Vector2(plot.end.x - 30, size.y - 4), "now", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, UITheme.C_TEXT_M)
	_line(_twin, plot, yr, UITheme.C_PRIMARY)
	_line(_real, plot, yr, UITheme.C_AMBER)
	var lx := plot.end.x - 150.0
	draw_rect(Rect2(lx, plot.position.y + 4, 10, 3), UITheme.C_PRIMARY)
	draw_string(_font, Vector2(lx + 14, plot.position.y + 10), "twin", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, UITheme.C_TEXT_S)
	draw_rect(Rect2(lx + 60, plot.position.y + 4, 10, 3), UITheme.C_AMBER)
	draw_string(_font, Vector2(lx + 74, plot.position.y + 10), "real board", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, UITheme.C_TEXT_S)


func _line(series: Array, plot: Rect2, yr: Vector2, col: Color) -> void:
	var pts := PackedVector2Array()
	var span := _t1 - _t0
	for i in series.size():
		var t := float(series[i][0])
		var v := float(series[i][1])
		var t_next := float(series[i + 1][0]) if i + 1 < series.size() else _t1
		if is_nan(v) or t_next < _t0 or t > _t1:
			if pts.size() >= 2:
				draw_polyline(pts, col, 1.6, true)
			pts = PackedVector2Array()
			continue
		var x0 := plot.position.x + clampf((t - _t0) / span, 0.0, 1.0) * plot.size.x
		var x1 := plot.position.x + clampf((t_next - _t0) / span, 0.0, 1.0) * plot.size.x
		var y := plot.end.y - clampf((v - yr.x) / (yr.y - yr.x), 0.0, 1.0) * plot.size.y
		pts.append(Vector2(x0, y))
		pts.append(Vector2(x1, y))
	if pts.size() >= 2:
		draw_polyline(pts, col, 1.6, true)
