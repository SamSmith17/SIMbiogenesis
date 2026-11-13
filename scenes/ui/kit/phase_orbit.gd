class_name PhaseOrbit
extends Control

## A phase-space orbit (plans/FLOW_VIZ_PLAN.md Part D): two stores traced
## against each other hour by hour, e.g. the battery's charge across and a
## tank's fill up. A site in a steady daily rhythm draws the same loop every
## day (a limit cycle); one running down spirals off. Older hours fade into
## the surface and the newest are bright, so the direction of travel reads
## without a legend; the start and the end are marked and named.
##
##   set_data(xs, ys, {x_label, y_label, x_fmt, y_fmt: Callable(v) -> String,
##            x_range, y_range: Vector2, t_label: Callable(i) -> String,
##            color: Color})

const PAD_L := 44.0
const PAD_B := 30.0
const PAD_T := 8.0
const PAD_R := 12.0

var xs := PackedFloat32Array()
var ys := PackedFloat32Array()
var opts: Dictionary = {}
var _xr := Vector2(0.0, 1.0)
var _yr := Vector2(0.0, 1.0)
var _hover := -1


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size.y = maxf(custom_minimum_size.y, 220.0)
	mouse_exited.connect(func() -> void:
		_hover = -1
		queue_redraw())


func set_data(x: PackedFloat32Array, y: PackedFloat32Array, o: Dictionary = {}) -> void:
	xs = x
	ys = y
	opts = o
	_xr = _fit_range(PatternData.finite_range(x), o.get("x_range", Vector2(NAN, NAN)))
	_yr = _fit_range(PatternData.finite_range(y), o.get("y_range", Vector2(NAN, NAN)))
	_hover = -1
	queue_redraw()


## The data's own range with a tenth either side (at least 4 % of the
## bounds), clamped inside `bounds` when given: a battery that moves between
## 12 and 19 % fills the plot instead of a corner of 0..100.
static func _fit_range(data: Vector2, bounds: Vector2) -> Vector2:
	if is_nan(data.x):
		return _pad_range(bounds)
	var span := data.y - data.x
	var min_span := 0.04 * (bounds.y - bounds.x) if not is_nan(bounds.x) else 1e-6
	var pad := maxf(span * 0.1, maxf(min_span - span, 0.0) * 0.5 + 1e-6)
	var r := Vector2(data.x - pad, data.y + pad)
	if not is_nan(bounds.x):
		r = Vector2(maxf(r.x, bounds.x), minf(r.y, bounds.y))
		if r.y - r.x < min_span:
			r = Vector2(clampf(r.x, bounds.x, bounds.y - min_span), 0.0)
			r.y = r.x + min_span
	return _pad_range(r)


static func _pad_range(r: Vector2) -> Vector2:
	if is_nan(r.x):
		return Vector2(0.0, 1.0)
	if r.y - r.x < 1e-9:
		return Vector2(r.x - 0.5, r.y + 0.5)
	return r


func _plot_rect() -> Rect2:
	return Rect2(Vector2(PAD_L, PAD_T), Vector2(maxf(size.x - PAD_L - PAD_R, 10.0),
		maxf(size.y - PAD_T - PAD_B, 10.0)))


func _to_px(x: float, y: float) -> Vector2:
	var r := _plot_rect()
	return Vector2(r.position.x + (x - _xr.x) / (_xr.y - _xr.x) * r.size.x,
		r.end.y - (y - _yr.x) / (_yr.y - _yr.x) * r.size.y)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var p := (event as InputEventMouseMotion).position
		var best := -1
		var bd := 14.0 * 14.0
		for i in mini(xs.size(), ys.size()):
			if is_nan(xs[i]) or is_nan(ys[i]):
				continue
			var d := _to_px(xs[i], ys[i]).distance_squared_to(p)
			if d < bd:
				bd = d
				best = i
		if best != _hover:
			_hover = best
			queue_redraw()


func _fmt(key: String, v: float) -> String:
	var f: Callable = opts.get(key, Callable())
	return str(f.call(v)) if f.is_valid() else "%.3g" % v


func _draw() -> void:
	var font := UITheme.font("regular", true)
	var r := _plot_rect()
	draw_rect(r, Color(UITheme.C_PANEL, 0.35))
	# Recessive grid: quarters.
	for k in 5:
		var fx := r.position.x + r.size.x * float(k) / 4.0
		var fy := r.position.y + r.size.y * float(k) / 4.0
		draw_line(Vector2(fx, r.position.y), Vector2(fx, r.end.y), Color(UITheme.C_BORDER, 0.35), 1.0)
		draw_line(Vector2(r.position.x, fy), Vector2(r.end.x, fy), Color(UITheme.C_BORDER, 0.35), 1.0)
	draw_string(font, Vector2(r.position.x, r.end.y + 13.0), _fmt("x_fmt", _xr.x),
		HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_XS, UITheme.C_TEXT_M)
	draw_string(font, Vector2(r.end.x - 60.0, r.end.y + 13.0), _fmt("x_fmt", _xr.y),
		HORIZONTAL_ALIGNMENT_RIGHT, 60, UITheme.FONT_XS, UITheme.C_TEXT_M)
	draw_string(font, Vector2(r.position.x, r.end.y + 26.0), str(opts.get("x_label", "")),
		HORIZONTAL_ALIGNMENT_CENTER, r.size.x, UITheme.FONT_SM, UITheme.C_TEXT_S)
	draw_string(font, Vector2(2.0, r.position.y + 9.0), _fmt("y_fmt", _yr.y),
		HORIZONTAL_ALIGNMENT_LEFT, PAD_L - 4.0, UITheme.FONT_XS, UITheme.C_TEXT_M)
	draw_string(font, Vector2(2.0, r.end.y), _fmt("y_fmt", _yr.x),
		HORIZONTAL_ALIGNMENT_LEFT, PAD_L - 4.0, UITheme.FONT_XS, UITheme.C_TEXT_M)
	draw_set_transform(Vector2(12.0, r.position.y + r.size.y * 0.5), -PI * 0.5)
	draw_string(font, Vector2(-r.size.y * 0.5, 0.0), str(opts.get("y_label", "")),
		HORIZONTAL_ALIGNMENT_CENTER, r.size.y, UITheme.FONT_SM, UITheme.C_TEXT_S)
	draw_set_transform(Vector2.ZERO)
	var n := mini(xs.size(), ys.size())
	if n < 2:
		draw_string(font, r.position + Vector2(8, 20), "Not enough hours recorded yet.",
			HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_SM, UITheme.C_TEXT_M)
		return
	var col: Color = opts.get("color", UITheme.C_PRIMARY)
	var pts := PackedVector2Array()
	var cs := PackedColorArray()
	var first := -1
	var last := -1
	for i in n:
		if is_nan(xs[i]) or is_nan(ys[i]):
			if pts.size() >= 2:
				draw_polyline_colors(pts, cs, 2.0, true)
			pts = PackedVector2Array()
			cs = PackedColorArray()
			continue
		if first < 0:
			first = i
		last = i
		pts.append(_to_px(xs[i], ys[i]))
		var age := float(i) / float(n - 1)
		cs.append(Color(col, 0.12 + 0.88 * age * age))
	if pts.size() >= 2:
		draw_polyline_colors(pts, cs, 2.0, true)
	var tl: Callable = opts.get("t_label", Callable())
	if first >= 0:
		var a := _to_px(xs[first], ys[first])
		draw_arc(a, 5.0, 0.0, TAU, 20, UITheme.C_TEXT_S, 1.5, true)
		draw_string(font, a + Vector2(8.0, -6.0), "start", HORIZONTAL_ALIGNMENT_LEFT, -1,
			UITheme.FONT_XS, UITheme.C_TEXT_S)
	if last >= 0:
		var b := _to_px(xs[last], ys[last])
		draw_circle(b, 5.5, col, true, -1.0, true)
		draw_arc(b, 7.5, 0.0, TAU, 20, UITheme.C_BG, 2.0, true)
		var lab := b + Vector2(9.0, 4.0)
		if first >= 0 and b.distance_to(_to_px(xs[first], ys[first])) < 24.0:
			lab = b + Vector2(9.0, 18.0)
		draw_string(font, lab, "now", HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_XS, UITheme.C_TEXT)
	if _hover >= 0:
		var hp := _to_px(xs[_hover], ys[_hover])
		draw_circle(hp, 4.0, UITheme.C_TEXT, true, -1.0, true)
		var txt := "%s · %s %s · %s %s" % [str(tl.call(_hover)) if tl.is_valid() else "hour %d" % _hover,
			str(opts.get("x_label", "x")), _fmt("x_fmt", xs[_hover]),
			str(opts.get("y_label", "y")), _fmt("y_fmt", ys[_hover])]
		var tw := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_SM).x + 12.0
		var bx := clampf(hp.x + 10.0, 0.0, size.x - tw)
		var by := clampf(hp.y - 28.0, 0.0, size.y - 20.0)
		draw_rect(Rect2(bx, by, tw, 20.0), Color(UITheme.C_BG, 0.94))
		draw_rect(Rect2(bx, by, tw, 20.0), UITheme.C_BORDER, false, 1.0)
		draw_string(font, Vector2(bx + 6.0, by + 14.0), txt, HORIZONTAL_ALIGNMENT_LEFT, -1,
			UITheme.FONT_SM, UITheme.C_TEXT)
