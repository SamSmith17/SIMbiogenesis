class_name TrendChart
extends Control

## A trend chart with several pens (SCADA plan, Phase 8): any readings over
## time on one plot, a cursor that reads every pen at the hovered instant,
## wheel zoom about the pointer, drag to pan.
##
##   pens      [{id, label, unit, color?, binary?}]
##   fetch     Callable(id, t0, t1, n) -> PackedFloat32Array (NAN = no reading)
##   now_fn    Callable() -> float (hours on the same axis as fetch)
##   span_h    hours shown;  end_h  right edge (NAN = follows now)
##
## Pens with the same unit share one scale; each other unit has its own, so
## a level in % and a power in kW can stand on one chart. The left axis shows
## the scale of the pen under the cursor's legend row (else the first pen).
## It only reads: nothing here writes a tag.

signal view_changed

const PEN_COLORS := [Color("#3987e5"), Color("#d95926"), Color("#199e70"), Color("#c98500"),
	Color("#d55181"), Color("#9085e9"), Color("#e66767"), Color("#5bbcd6")]
const SPAN_MIN_H := 0.05
const SPAN_MAX_H := 24.0 * 14.0
const REFRESH_S := 0.5
const PAD_L := 54.0
const PAD_R := 12.0
const PAD_T := 10.0
const PAD_B := 24.0
const BG := Color(0.043, 0.059, 0.098)
const GRID := Color(0.16, 0.20, 0.28, 0.55)

var pens: Array = []
var fetch: Callable = Callable()
var now_fn: Callable = Callable()
var span_h := 2.0
var end_h := NAN
var axis_pen := 0

var _data: Array = []          # per pen: PackedFloat32Array
var _scale: Array = []         # per pen: Vector2(lo, hi)
var _t0 := 0.0
var _t1 := 1.0
var _acc := 0.0
var _hover := Vector2(-1, -1)
var _panning := false
var _press_x := 0.0
var _font: Font = null
var _draw_us := 0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_CLICK
	clip_contents = true
	custom_minimum_size = Vector2(320, 180)


func _ready() -> void:
	_font = UITheme.font("regular", true)
	resized.connect(refresh)
	mouse_exited.connect(func() -> void:
		_hover = Vector2(-1, -1)
		queue_redraw())
	refresh()


func set_pens(p: Array) -> void:
	pens = p.duplicate(true)
	for i in pens.size():
		if not (pens[i] as Dictionary).has("color"):
			pens[i]["color"] = PEN_COLORS[i % PEN_COLORS.size()]
	axis_pen = clampi(axis_pen, 0, maxi(pens.size() - 1, 0))
	refresh()


func set_span(hours: float) -> void:
	span_h = clampf(hours, SPAN_MIN_H, SPAN_MAX_H)
	refresh()
	view_changed.emit()


## Back to the live edge.
func follow_now() -> void:
	end_h = NAN
	refresh()
	view_changed.emit()


func following() -> bool:
	return is_nan(end_h)


func plot_rect() -> Rect2:
	return Rect2(PAD_L, PAD_T, maxf(size.x - PAD_L - PAD_R, 10.0), maxf(size.y - PAD_T - PAD_B, 10.0))


func _now() -> float:
	return float(now_fn.call()) if now_fn.is_valid() else 0.0


func time_range() -> Vector2:
	return Vector2(_t0, _t1)


## How many samples pen `i` holds that are readings.
func points(i: int) -> int:
	if i < 0 or i >= _data.size():
		return 0
	var n := 0
	for v in (_data[i] as PackedFloat32Array):
		if not is_nan(v):
			n += 1
	return n


func scale_of(i: int) -> Vector2:
	return _scale[i] if i >= 0 and i < _scale.size() else Vector2(0, 1)


func draw_cost_ms() -> float:
	return float(_draw_us) / 1000.0


func refresh() -> void:
	var now := _now()
	_t1 = now if is_nan(end_h) else end_h
	_t0 = _t1 - span_h
	_data = []
	_scale = []
	var n := clampi(int(plot_rect().size.x / 3.0), 40, 420)
	for p in pens:
		_data.append(fetch.call(str(p["id"]), _t0, _t1, n) if fetch.is_valid() else PackedFloat32Array())
	# One scale per unit.
	var by_unit := {}
	for i in pens.size():
		var p: Dictionary = pens[i]
		if bool(p.get("binary", false)):
			continue
		var u := str(p.get("unit", ""))
		var mm: Vector2 = by_unit.get(u, Vector2(INF, -INF))
		for v in (_data[i] as PackedFloat32Array):
			if not is_nan(v):
				mm.x = minf(mm.x, v)
				mm.y = maxf(mm.y, v)
		by_unit[u] = mm
	for i in pens.size():
		var p: Dictionary = pens[i]
		if bool(p.get("binary", false)):
			_scale.append(Vector2(-0.15, 1.15))
			continue
		var mm: Vector2 = by_unit.get(str(p.get("unit", "")), Vector2(INF, -INF))
		if mm.y < mm.x:
			mm = Vector2(0.0, 1.0)
		if str(p.get("unit", "")) == "%" and mm.x >= 0.0 and mm.y <= 100.0:
			mm = Vector2(0.0, 100.0)
		else:
			var pad := maxf((mm.y - mm.x) * 0.1, maxf(absf(mm.y), 1.0) * 0.02)
			mm = Vector2(mm.x - pad, mm.y + pad)
		_scale.append(mm)
	queue_redraw()


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_acc += delta
	if _acc >= REFRESH_S:
		_acc = 0.0
		refresh()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			var pr := plot_rect()
			var f := clampf((mb.position.x - pr.position.x) / pr.size.x, 0.0, 1.0)
			var t_at := _t0 + (_t1 - _t0) * f
			var ns := clampf(span_h * (1.0 / 1.25 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.25), SPAN_MIN_H, SPAN_MAX_H)
			var ne := t_at + ns * (1.0 - f)
			span_h = ns
			end_h = NAN if ne >= _now() - 1e-6 else ne
			refresh()
			view_changed.emit()
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			_panning = mb.pressed
			_press_x = mb.position.x
			accept_event()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		_hover = mm.position
		if _panning and (mm.button_mask & MOUSE_BUTTON_MASK_LEFT) == 0:
			_panning = false
		if _panning:
			var pr := plot_rect()
			var dt := -(mm.position.x - _press_x) / pr.size.x * span_h
			_press_x = mm.position.x
			if absf(dt) > 0.0:
				var ne := _t1 + dt
				end_h = NAN if ne >= _now() - 1e-6 else ne
				refresh()
				view_changed.emit()
		queue_redraw()


## The time under a control x (hours), and each pen's reading there.
func cursor_at(x: float) -> Dictionary:
	var pr := plot_rect()
	var f := clampf((x - pr.position.x) / pr.size.x, 0.0, 1.0)
	var vals: Array = []
	for i in pens.size():
		var d: PackedFloat32Array = _data[i] if i < _data.size() else PackedFloat32Array()
		vals.append(d[clampi(int(round(f * float(d.size() - 1))), 0, d.size() - 1)] if d.size() > 0 else NAN)
	return {"t": _t0 + (_t1 - _t0) * f, "values": vals}


static func ago_text(h: float) -> String:
	if h < 1.0 / 120.0:
		return "now"
	if h < 1.0:
		return "%d min ago" % int(round(h * 60.0))
	if h < 48.0:
		return "%s h ago" % (("%.1f" % h) if h < 10.0 else str(int(round(h))))
	return "%.1f days ago" % (h / 24.0)


static func value_text(v: float, unit: String, binary: bool) -> String:
	if is_nan(v):
		return "no reading"
	if binary:
		return "On" if v > 0.5 else "Off"
	return "%s%s" % [MimicWidgets.fmt(v), (" " + unit) if not unit.is_empty() else ""]


func _draw() -> void:
	var t0 := Time.get_ticks_usec()
	draw_rect(Rect2(Vector2.ZERO, size), BG)
	var pr := plot_rect()
	var fs := 11
	# Grid + the left axis (the axis pen's scale).
	var ax := scale_of(axis_pen) if not pens.is_empty() else Vector2(0, 1)
	var ax_unit := str((pens[axis_pen] as Dictionary).get("unit", "")) if not pens.is_empty() else ""
	var ax_col: Color = (pens[axis_pen] as Dictionary).get("color", UITheme.C_TEXT_M) if not pens.is_empty() else UITheme.C_TEXT_M
	for g in 5:
		var gy := pr.end.y - pr.size.y * float(g) / 4.0
		draw_line(Vector2(pr.position.x, gy), Vector2(pr.end.x, gy), GRID, 1.0)
		if _font != null and not pens.is_empty() and not bool((pens[axis_pen] as Dictionary).get("binary", false)):
			draw_string(_font, Vector2(2.0, gy + 4.0), MimicWidgets.fmt(lerpf(ax.x, ax.y, float(g) / 4.0)), HORIZONTAL_ALIGNMENT_RIGHT, PAD_L - 8.0, fs, Color(ax_col, 0.9))
	if _font != null and not ax_unit.is_empty():
		draw_string(_font, Vector2(2.0, pr.position.y + 4.0 - 14.0 + 14.0), "", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, ax_col)
	var now := _now()
	for g in 5:
		var gx := pr.position.x + pr.size.x * float(g) / 4.0
		draw_line(Vector2(gx, pr.position.y), Vector2(gx, pr.end.y), GRID, 1.0)
		if _font != null:
			var th := _t0 + (_t1 - _t0) * float(g) / 4.0
			var txt := ago_text(maxf(now - th, 0.0))
			var al := HORIZONTAL_ALIGNMENT_CENTER if g > 0 and g < 4 else (HORIZONTAL_ALIGNMENT_LEFT if g == 0 else HORIZONTAL_ALIGNMENT_RIGHT)
			var x0 := gx - 60.0 if g > 0 and g < 4 else (gx if g == 0 else gx - 120.0)
			draw_string(_font, Vector2(x0, pr.end.y + 16.0), txt, al, 120.0, fs, UITheme.C_TEXT_M)
	# Pens.
	for i in pens.size():
		var d: PackedFloat32Array = _data[i] if i < _data.size() else PackedFloat32Array()
		var n := d.size()
		if n < 2:
			continue
		var sc := scale_of(i)
		var col: Color = (pens[i] as Dictionary).get("color", Color.WHITE)
		var run := PackedVector2Array()
		for k in n:
			var v := d[k]
			if is_nan(v):
				if run.size() >= 2:
					draw_polyline(run, col, 2.0, true)
				run = PackedVector2Array()
				continue
			run.append(Vector2(pr.position.x + pr.size.x * float(k) / float(n - 1),
				pr.end.y - pr.size.y * clampf((v - sc.x) / maxf(sc.y - sc.x, 1e-9), 0.0, 1.0)))
		if run.size() >= 2:
			draw_polyline(run, col, 2.0, true)
	draw_rect(pr, Color(0.36, 0.40, 0.47, 0.7), false, 1.0)
	# Cursor + legend (the reading of every pen at the cursor, else the latest).
	var cur := {}
	var hovering := pr.grow(2.0).has_point(_hover)
	if hovering:
		cur = cursor_at(_hover.x)
		draw_line(Vector2(_hover.x, pr.position.y), Vector2(_hover.x, pr.end.y), Color(UITheme.C_TEXT, 0.55), 1.0)
	else:
		cur = cursor_at(pr.end.x)
	if _font != null and not pens.is_empty():
		var ly := pr.position.y + 8.0
		var lx := pr.position.x + 10.0
		var head := ago_text(maxf(now - float(cur["t"]), 0.0)) if hovering else "latest"
		var rows: Array = [[head, UITheme.C_TEXT_M]]
		for i in pens.size():
			var p: Dictionary = pens[i]
			rows.append(["%s   %s" % [str(p.get("label", p["id"])), value_text(float(cur["values"][i]), str(p.get("unit", "")), bool(p.get("binary", false)))], p["color"]])
		var wmax := 0.0
		for r in rows:
			wmax = maxf(wmax, _font.get_string_size(str(r[0]), HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x)
		wmax = minf(wmax, pr.size.x - 40.0)
		draw_rect(Rect2(lx - 6.0, ly - 4.0, wmax + 30.0, float(rows.size()) * (fs + 5.0) + 6.0), Color(0.05, 0.07, 0.11, 0.86))
		for k in rows.size():
			var by := ly + float(k) * (fs + 5.0) + fs
			if k > 0:
				draw_rect(Rect2(lx, by - fs + 3.0, 10.0, fs - 4.0), rows[k][1])
				if hovering and cur["values"][k - 1] != null and not is_nan(float(cur["values"][k - 1])):
					var sc2 := scale_of(k - 1)
					var cy := pr.end.y - pr.size.y * clampf((float(cur["values"][k - 1]) - sc2.x) / maxf(sc2.y - sc2.x, 1e-9), 0.0, 1.0)
					draw_circle(Vector2(_hover.x, cy), 3.5, rows[k][1])
			draw_string(_font, Vector2(lx + (16.0 if k > 0 else 0.0), by), str(rows[k][0]), HORIZONTAL_ALIGNMENT_LEFT, wmax, fs, UITheme.C_TEXT if k > 0 else rows[k][1])
	if pens.is_empty() and _font != null:
		draw_string(_font, Vector2(pr.position.x, pr.get_center().y), "No pens yet. Add a tag to see it over time.", HORIZONTAL_ALIGNMENT_CENTER, pr.size.x, 13, UITheme.C_TEXT_M)
	_draw_us = Time.get_ticks_usec() - t0
