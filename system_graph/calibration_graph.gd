class_name CalibrationGraph
extends Control
## Lightweight live wattage plot used by the load calibrator.
## Accepts either:
##   - a reference to the calibrator's running buffer (Array of {t, w})
##   - a saved trace (Array of [t, w] pairs from load_calibration.trace)
## Auto-scales the Y-axis to peak watts and draws a horizontal "average" guide.

const C_BG       := Color(0.06, 0.07, 0.10, 1.0)
const C_BORDER   := Color(0.227, 0.290, 0.420, 1.0)
const C_GRID     := Color(0.18, 0.22, 0.30, 0.55)
const C_LINE     := Color(0.133, 0.827, 0.933, 1.0)
const C_FILL     := Color(0.133, 0.827, 0.933, 0.18)
const C_AVG      := Color(0.961, 0.620, 0.043, 0.85)
const C_NOW      := Color(0.961, 0.620, 0.043, 0.45)
const C_TEXT     := Color(0.580, 0.639, 0.722, 1.0)
const C_TEXT_DIM := Color(0.392, 0.447, 0.545, 1.0)

const PAD_L := 36.0
const PAD_R := 8.0
const PAD_T := 6.0
const PAD_B := 16.0

var _samples:    Array = []   # Each entry: Dictionary {t,w}  OR  Array [t,w]
var _duration_s: float = 30.0
var _avg_w:      float = 0.0
var _peak_w:     float = 0.0
var _live_w:     float = 0.0
var _now_t:      float = -1.0  # >=0 ⇒ draw vertical "now" line


func _ready() -> void:
	custom_minimum_size = Vector2(0, 110)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_data(samples: Array, duration_s: float, avg_w: float,
		peak_w: float, live_w: float, now_t: float = -1.0) -> void:
	_samples    = samples
	_duration_s = maxf(duration_s, 1.0)
	_avg_w      = avg_w
	_peak_w     = peak_w
	_live_w     = live_w
	_now_t      = now_t
	queue_redraw()


func clear_data() -> void:
	_samples = []
	_avg_w = 0.0
	_peak_w = 0.0
	_live_w = 0.0
	_now_t = -1.0
	queue_redraw()


func _draw() -> void:
	var sz := size
	if sz.x < 50.0 or sz.y < 30.0:
		return

	# Background
	draw_rect(Rect2(Vector2.ZERO, sz), C_BG, true)
	draw_rect(Rect2(Vector2.ZERO, sz), C_BORDER, false, 1.0)

	var plot_origin := Vector2(PAD_L, PAD_T)
	var plot_size   := Vector2(sz.x - PAD_L - PAD_R, sz.y - PAD_T - PAD_B)
	if plot_size.x <= 0.0 or plot_size.y <= 0.0:
		return

	# Compute Y range
	var y_max := maxf(_peak_w, _avg_w * 1.2)
	if y_max <= 0.0:
		y_max = 1.0
	# Round y_max up to a "nice" number so labels read cleanly
	y_max = _nice_ceil(y_max)

	var fnt := ThemeDB.fallback_font
	var fsize := 9

	# Horizontal grid + Y-axis labels (5 ticks)
	for i in 5:
		var frac: float = float(i) / 4.0
		var y: float = plot_origin.y + plot_size.y * (1.0 - frac)
		draw_line(Vector2(plot_origin.x, y),
			Vector2(plot_origin.x + plot_size.x, y), C_GRID, 1.0)
		var w_label: float = y_max * frac
		var label_str: String = "%.0f" % w_label
		draw_string(fnt, Vector2(2, y + 3),
			label_str, HORIZONTAL_ALIGNMENT_LEFT, PAD_L - 4, fsize, C_TEXT_DIM)

	# X-axis (just bottom border)
	draw_line(plot_origin + Vector2(0, plot_size.y),
		plot_origin + plot_size, C_BORDER, 1.0)

	# X-axis time labels (start, mid, end)
	var t_strs := [_fmt_t(0.0), _fmt_t(_duration_s * 0.5), _fmt_t(_duration_s)]
	var x_positions := [
		plot_origin.x,
		plot_origin.x + plot_size.x * 0.5,
		plot_origin.x + plot_size.x,
	]
	for i in 3:
		var x: float = x_positions[i]
		var ts: String = t_strs[i]
		var halign := HORIZONTAL_ALIGNMENT_CENTER
		if i == 0: halign = HORIZONTAL_ALIGNMENT_LEFT
		elif i == 2: halign = HORIZONTAL_ALIGNMENT_RIGHT
		draw_string(fnt, Vector2(x - 20, sz.y - 3),
			ts, halign, 40, fsize, C_TEXT_DIM)

	# Average reference line
	if _avg_w > 0.0:
		var ya: float = plot_origin.y + plot_size.y * (1.0 - clampf(_avg_w / y_max, 0.0, 1.0))
		draw_dashed_line(Vector2(plot_origin.x, ya),
			Vector2(plot_origin.x + plot_size.x, ya), C_AVG, 1.0, 4.0)
		draw_string(fnt, Vector2(plot_origin.x + plot_size.x - 60, ya - 2),
			"avg %.0f W" % _avg_w, HORIZONTAL_ALIGNMENT_RIGHT, 56, fsize, C_AVG)

	# Now-line
	if _now_t >= 0.0 and _duration_s > 0.0:
		var nx: float = plot_origin.x + plot_size.x * clampf(_now_t / _duration_s, 0.0, 1.0)
		draw_line(Vector2(nx, plot_origin.y),
			Vector2(nx, plot_origin.y + plot_size.y), C_NOW, 1.0)

	# Sample line + fill
	var n: int = _samples.size()
	if n < 2:
		# Single-sample overlay text
		draw_string(fnt, plot_origin + Vector2(plot_size.x * 0.5 - 50, plot_size.y * 0.5),
			"waiting for samples…", HORIZONTAL_ALIGNMENT_CENTER, 100, fsize + 1, C_TEXT_DIM)
		return

	var pts: PackedVector2Array = PackedVector2Array()
	pts.resize(n)
	for i in n:
		var sample: Variant = _samples[i]
		var t: float
		var w: float
		if sample is Dictionary:
			t = float((sample as Dictionary).get("t", 0.0))
			w = float((sample as Dictionary).get("w", 0.0))
		elif sample is Array and (sample as Array).size() >= 2:
			t = float((sample as Array)[0])
			w = float((sample as Array)[1])
		else:
			continue
		var fx: float = clampf(t / _duration_s, 0.0, 1.0)
		var fy: float = clampf(w / y_max, 0.0, 1.0)
		pts[i] = Vector2(
			plot_origin.x + plot_size.x * fx,
			plot_origin.y + plot_size.y * (1.0 - fy)
		)

	# Filled area under the curve
	var fill := PackedVector2Array()
	fill.append(Vector2(pts[0].x, plot_origin.y + plot_size.y))
	for p in pts:
		fill.append(p)
	fill.append(Vector2(pts[pts.size() - 1].x, plot_origin.y + plot_size.y))
	var fill_colors := PackedColorArray()
	fill_colors.resize(fill.size())
	for i in fill.size():
		fill_colors[i] = C_FILL
	draw_polygon(fill, fill_colors)

	# Polyline curve
	for i in range(1, pts.size()):
		draw_line(pts[i - 1], pts[i], C_LINE, 1.5)


func _fmt_t(s: float) -> String:
	if s < 60.0:
		return "%.0fs" % s
	if s < 3600.0:
		return "%.0fm" % (s / 60.0)
	return "%.1fh" % (s / 3600.0)


func _nice_ceil(v: float) -> float:
	if v <= 0.0:
		return 1.0
	var exp10 := pow(10.0, floor(log(v) / log(10.0)))
	var frac := v / exp10
	var nice: float
	if frac <= 1.0:    nice = 1.0
	elif frac <= 2.0:  nice = 2.0
	elif frac <= 5.0:  nice = 5.0
	else:              nice = 10.0
	return nice * exp10
