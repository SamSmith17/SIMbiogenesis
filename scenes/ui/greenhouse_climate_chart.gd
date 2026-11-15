class_name GreenhouseClimateChart
extends Control

## The designer's year at a glance: every day's coldest and warmest hour
## inside (a bar, blue below freezing, green in the growing range, amber hot)
## over the same day outside (grey), with 0 °C and month ticks. Hover reads
## a day. Data: GreenhouseYear.run's `daily`.

const PAD_L := 44.0
const PAD_R := 12.0
const PAD_T := 14.0
const PAD_B := 26.0
const MONTHS := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
const HOT_C := 35.0

var daily: Dictionary = {}
var _hover := -1


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	custom_minimum_size = Vector2(320, 220)
	mouse_exited.connect(func() -> void:
		_hover = -1
		queue_redraw())


func set_data(d: Dictionary) -> void:
	daily = d
	queue_redraw()


func _range() -> Vector2:
	var lo := 0.0
	var hi := 30.0
	for k in ["in_min", "out_min"]:
		for v in daily.get(k, PackedFloat32Array()):
			lo = minf(lo, float(v))
	for k in ["in_max", "out_max"]:
		for v in daily.get(k, PackedFloat32Array()):
			hi = maxf(hi, float(v))
	lo = floorf(lo / 10.0) * 10.0
	hi = ceilf(hi / 10.0) * 10.0
	return Vector2(lo, maxf(hi, lo + 10.0))


func _y(t: float, r: Vector2) -> float:
	var h := size.y - PAD_T - PAD_B
	return PAD_T + h * (1.0 - (t - r.x) / (r.y - r.x))


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion:
		var n := (daily.get("in_min", PackedFloat32Array()) as PackedFloat32Array).size()
		if n == 0:
			return
		var w := size.x - PAD_L - PAD_R
		var i := int(floor(((e as InputEventMouseMotion).position.x - PAD_L) / w * float(n)))
		var j := i if i >= 0 and i < n else -1
		if j != _hover:
			_hover = j
			queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), UITheme.C_BG)
	var imin: PackedFloat32Array = daily.get("in_min", PackedFloat32Array())
	var font := get_theme_default_font()
	if imin.is_empty():
		draw_string(font, Vector2(PAD_L, size.y * 0.5), "Run a year to see the climate inside", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, UITheme.C_TEXT_S)
		return
	var imax: PackedFloat32Array = daily["in_max"]
	var omin: PackedFloat32Array = daily["out_min"]
	var omax: PackedFloat32Array = daily["out_max"]
	var r := _range()
	var n := imin.size()
	var w := size.x - PAD_L - PAD_R
	var bw := w / float(n)
	# Grid: every 10 °C, 0 °C stronger.
	var t := r.x
	while t <= r.y + 0.01:
		var y := _y(t, r)
		draw_line(Vector2(PAD_L, y), Vector2(size.x - PAD_R, y), Color(1, 1, 1, 0.18 if absf(t) < 0.01 else 0.06), 1.0)
		draw_string(font, Vector2(4, y + 4), "%d °C" % int(t), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, UITheme.C_TEXT_S)
		t += 10.0
	# Months.
	var doy := 0
	for m in 12:
		var x := PAD_L + float(doy) * bw
		if doy < n:
			draw_line(Vector2(x, PAD_T), Vector2(x, size.y - PAD_B), Color(1, 1, 1, 0.05), 1.0)
			draw_string(font, Vector2(x + 2, size.y - 8), MONTHS[m], HORIZONTAL_ALIGNMENT_LEFT, -1, 11, UITheme.C_TEXT_S)
		doy += int(GreenhouseYear.DAYS_IN_MONTH[m])
	# Outside, then inside.
	for i in n:
		var x := PAD_L + (float(i) + 0.5) * bw
		draw_line(Vector2(x, _y(omin[i], r)), Vector2(x, _y(omax[i], r)), Color(0.6, 0.62, 0.66, 0.35), maxf(bw, 1.0))
	for i in n:
		var x := PAD_L + (float(i) + 0.5) * bw
		var c := Color(0.45, 0.8, 0.5, 0.95)
		if imin[i] < 0.0:
			c = Color(0.45, 0.65, 1.0, 0.95)
		elif imax[i] > HOT_C:
			c = Color(1.0, 0.65, 0.3, 0.95)
		draw_line(Vector2(x, _y(imin[i], r)), Vector2(x, _y(imax[i], r)), c, maxf(bw * 0.6, 1.0))
	if _hover >= 0 and _hover < n:
		var x := PAD_L + (float(_hover) + 0.5) * bw
		draw_line(Vector2(x, PAD_T), Vector2(x, size.y - PAD_B), Color(1, 1, 1, 0.4), 1.0)
		var md := GreenhouseYear.month_day(_hover)
		var txt := "%s %d · inside %.0f to %.0f °C · outside %.0f to %.0f °C" % [MONTHS[md.x - 1], md.y,
			imin[_hover], imax[_hover], omin[_hover], omax[_hover]]
		var dli: PackedFloat32Array = daily.get("dli", PackedFloat32Array())
		if _hover < dli.size():
			txt += " · light %.0f mol/m²" % dli[_hover]
		var tw := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
		var tx := clampf(x - tw * 0.5, PAD_L, size.x - PAD_R - tw)
		draw_rect(Rect2(tx - 4, PAD_T, tw + 8, 18), Color(0, 0, 0, 0.7))
		draw_string(font, Vector2(tx, PAD_T + 13), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, UITheme.C_TEXT)
	# Key.
	var ky := PAD_T + 2.0
	if _hover < 0:
		var keys := [[Color(0.6, 0.62, 0.66), "outside"], [Color(0.45, 0.8, 0.5), "inside"],
			[Color(0.45, 0.65, 1.0), "below 0 °C"], [Color(1.0, 0.65, 0.3), "over 35 °C"]]
		var tot := 0.0
		for e in keys:
			tot += 14.0 + font.get_string_size(str(e[1]), HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x + 12.0
		var kx := size.x - PAD_R - tot
		for e in keys:
			draw_rect(Rect2(kx, ky + 3, 10, 10), e[0])
			draw_string(font, Vector2(kx + 14, ky + 12), str(e[1]), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, UITheme.C_TEXT_S)
			kx += 14.0 + font.get_string_size(str(e[1]), HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x + 12.0
