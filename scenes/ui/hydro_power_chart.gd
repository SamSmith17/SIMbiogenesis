extends Control

## Hydro Lab power-curve chart: P (W) vs gross head (m), one polyline per pipe
## size, with the turbine's CURRENT operating point marked — the visual answer
## to "what does more drop / a fatter pipe buy me". Pure _draw over data pushed
## by the Lab (set_data / set_marker); no model access, no per-frame recompute
## (the Lab change-gates recomputes on a parameter signature and only nudges
## the marker as the pond level moves). SiteReportCharts drawing conventions.

const C_BG := Color(0.05, 0.08, 0.13, 0.55)
const C_GRID := Color(0.35, 0.45, 0.60, 0.22)
const C_AXIS := Color(0.60, 0.72, 0.88, 0.65)
const C_TEXT := Color(0.72, 0.80, 0.92, 0.9)
const C_MARKER := Color(1.0, 0.82, 0.35, 1.0)

const MARGIN_L := 40.0
const MARGIN_B := 20.0
const MARGIN_T := 8.0
const MARGIN_R := 8.0

## [{label: String, color: Color, pts: PackedVector2Array (x = head m, y = W)}]
var _curves: Array = []
var _marker := Vector2.INF
var _x_label := "head m"
var _y_label := "W"


func set_data(curves: Array, marker: Vector2 = Vector2.INF,
		x_label: String = "head m", y_label: String = "W") -> void:
	_curves = curves
	_marker = marker
	_x_label = x_label
	_y_label = y_label
	queue_redraw()


## Cheap marker-only update (pond level moved; the curves are unchanged).
func set_marker(marker: Vector2) -> void:
	if _marker.is_equal_approx(marker):
		return
	_marker = marker
	queue_redraw()


func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	draw_rect(r, C_BG)
	var plot := Rect2(MARGIN_L, MARGIN_T,
			maxf(size.x - MARGIN_L - MARGIN_R, 8.0),
			maxf(size.y - MARGIN_T - MARGIN_B, 8.0))
	# Data bounds over every curve (+ marker).
	var x_max := 1.0
	var y_max := 1.0
	for c: Variant in _curves:
		for p: Vector2 in (c as Dictionary).get("pts", PackedVector2Array()):
			x_max = maxf(x_max, p.x)
			y_max = maxf(y_max, p.y)
	if is_finite(_marker.x):
		x_max = maxf(x_max, _marker.x)
		y_max = maxf(y_max, _marker.y)
	y_max *= 1.08
	var fnt := ThemeDB.fallback_font
	# Grid + axis labels (4 divisions each way).
	for i in range(5):
		var t := float(i) / 4.0
		var gx := plot.position.x + plot.size.x * t
		var gy := plot.position.y + plot.size.y * (1.0 - t)
		draw_line(Vector2(gx, plot.position.y), Vector2(gx, plot.end.y), C_GRID, 1.0)
		draw_line(Vector2(plot.position.x, gy), Vector2(plot.end.x, gy), C_GRID, 1.0)
		if i % 2 == 0:
			draw_string(fnt, Vector2(gx - 8.0, plot.end.y + 13.0),
					"%.0f" % (x_max * t), HORIZONTAL_ALIGNMENT_LEFT, -1, 9, C_TEXT)
			draw_string(fnt, Vector2(2.0, gy + 3.0),
					_fmt_w(y_max * t), HORIZONTAL_ALIGNMENT_LEFT, -1, 9, C_TEXT)
	draw_line(plot.position + Vector2(0, plot.size.y), plot.end, C_AXIS, 1.2)
	draw_line(plot.position, plot.position + Vector2(0, plot.size.y), C_AXIS, 1.2)
	draw_string(fnt, Vector2(plot.end.x - 46.0, plot.end.y + 13.0), _x_label,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 9, C_AXIS)
	# Curves + legend.
	var legend_y := plot.position.y + 10.0
	for c: Variant in _curves:
		var cd: Dictionary = c
		var col: Color = cd.get("color", Color.WHITE)
		var pts: PackedVector2Array = cd.get("pts", PackedVector2Array())
		var screen := PackedVector2Array()
		for p: Vector2 in pts:
			screen.append(_to_screen(p, plot, x_max, y_max))
		var current := bool(cd.get("current", false))
		if screen.size() >= 2:
			draw_polyline(screen, col, 2.8 if current else 1.6, true)
		draw_line(Vector2(plot.position.x + 6.0, legend_y),
				Vector2(plot.position.x + 20.0, legend_y), col, 3.6 if current else 2.4)
		draw_string(fnt, Vector2(plot.position.x + 24.0, legend_y + 3.5),
				str(cd.get("label", "")) + (" ◂ yours" if current else ""),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 9, C_TEXT if not current else Color(1.0, 0.95, 0.85))
		legend_y += 12.0
	# Operating-point marker: "you are here".
	if is_finite(_marker.x):
		var mp := _to_screen(_marker, plot, x_max, y_max)
		draw_circle(mp, 4.0, C_MARKER)
		draw_arc(mp, 6.5, 0.0, TAU, 20, Color(C_MARKER.r, C_MARKER.g, C_MARKER.b, 0.5), 1.2)
		draw_string(fnt, mp + Vector2(8.0, -4.0), _fmt_w(_marker.y),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 10, C_MARKER)


func _to_screen(p: Vector2, plot: Rect2, x_max: float, y_max: float) -> Vector2:
	return Vector2(
		plot.position.x + plot.size.x * clampf(p.x / x_max, 0.0, 1.0),
		plot.end.y - plot.size.y * clampf(p.y / y_max, 0.0, 1.0))


func _fmt_w(w: float) -> String:
	if w >= 1000.0:
		return "%.1f kW" % (w / 1000.0)
	return "%.0f W" % w
