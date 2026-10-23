class_name ExperimentCompareChart
extends Control

## Stacked lanes (battery %, solar, load, net) with several ExperimentSeries
## overlaid on one time axis: reality drawn as a band (its min–max per bin)
## with its mean line, each sim as a line. Bins are TimelineBinning's
## zoom-stable ones, so a fast signal reads as an envelope at a week's width.
## Hover: a cursor line and every series' value at that time.

const LANES := [
	{"ch": "soc_pct", "label": "Battery", "unit": "%", "fixed": [0.0, 100.0]},
	{"ch": "solar_kw", "label": "Solar", "unit": "kW"},
	{"ch": "load_kw", "label": "Load", "unit": "kW"},
	{"ch": "net_kw", "label": "Net", "unit": "kW"},
]
const LANE_H := 92.0
const LANE_GAP := 8.0
const AXIS_H := 18.0
const LEFT_W := 86.0

## [{series: ExperimentSeries, color: Color, band: bool}]
var _items: Array = []
var _span := PackedFloat64Array([0.0, 0.0])
var _clock: Object = null
var _hover_x := -1.0
var _cache: Dictionary = {}


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	custom_minimum_size = Vector2(0, LANES.size() * (LANE_H + LANE_GAP) + AXIS_H)
	clip_contents = true
	resized.connect(func() -> void:
		_cache.clear()
		queue_redraw())


## `span` = [start, end] absolute hours (64-bit; a Vector2 rounds them to 2 h).
func set_data(items: Array, span: PackedFloat64Array, clock: Object) -> void:
	_items = items
	_span = span
	_clock = clock
	_cache.clear()
	queue_redraw()


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion:
		_hover_x = (e as InputEventMouseMotion).position.x
		queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT:
		_hover_x = -1.0
		queue_redraw()


func _plot_rect() -> Rect2:
	return Rect2(LEFT_W, 0.0, maxf(size.x - LEFT_W - 4.0, 10.0), size.y - AXIS_H)


func _draw() -> void:
	var font := UITheme.font("regular", true)
	var pr := _plot_rect()
	var view_span := _span[1] - _span[0]
	if view_span <= 0.0 or _items.is_empty():
		draw_string(font, Vector2(LEFT_W, 24.0), "Run a comparison to see the curves here.",
			HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_SM, UITheme.C_TEXT_M)
		return
	var min_step := INF
	for it in _items:
		min_step = minf(min_step, (it["series"] as ExperimentSeries).step_h)
	var w := TimelineBinning.bin_width(view_span, pr.size.x, min_step)
	var g := TimelineBinning.grid(_span[0], _span[1], w)
	var y := 0.0
	for lane in LANES:
		var ch := str(lane["ch"])
		var r := Rect2(pr.position.x, y, pr.size.x, LANE_H)
		draw_rect(r, Color(UITheme.C_PANEL_RAISED, 0.55), true)
		draw_rect(r, Color(UITheme.C_BORDER, 0.6), false, 1.0)
		var bins_list: Array = []
		var lo := INF
		var hi := -INF
		for it in _items:
			var s: ExperimentSeries = it["series"]
			if not s.has(ch):
				bins_list.append({})
				continue
			var key := "%s|%d|%s|%d" % [ch, s.get_instance_id(), str(w), int(g["i0"])]
			if not _cache.has(key):
				_cache[key] = s.bins(ch, w, int(g["i0"]), int(g["n"]))
			var b: Dictionary = _cache[key]
			bins_list.append(b)
			var vr := TimelineBinning.value_range(b)
			if not is_nan(vr.x):
				lo = minf(lo, vr.x)
				hi = maxf(hi, vr.y)
		if lane.has("fixed"):
			lo = float(lane["fixed"][0])
			hi = float(lane["fixed"][1])
		elif is_inf(lo):
			lo = 0.0
			hi = 1.0
		else:
			lo = minf(lo, 0.0)
			hi = maxf(hi, lo + 0.1)
			var padv := (hi - lo) * 0.06
			hi += padv
			if lo < 0.0:
				lo -= padv
		if lo < 0.0 and hi > 0.0:
			var zy := _y(0.0, lo, hi, r)
			draw_line(Vector2(r.position.x, zy), Vector2(r.end.x, zy), Color(UITheme.C_TEXT_M, 0.5), 1.0)
		for k in _items.size():
			var b: Dictionary = bins_list[k]
			if b.is_empty():
				continue
			_draw_series(r, b, lo, hi, _items[k]["color"], bool(_items[k].get("band", false)))
		draw_string(font, Vector2(4.0, y + 16.0), str(lane["label"]), HORIZONTAL_ALIGNMENT_LEFT,
			int(LEFT_W - 8.0), UITheme.FONT_SM, UITheme.C_TEXT)
		draw_string(font, Vector2(4.0, y + 32.0), "%s – %s %s" % [_fmt(lo), _fmt(hi), str(lane["unit"])],
			HORIZONTAL_ALIGNMENT_LEFT, int(LEFT_W - 8.0), UITheme.FONT_XS, UITheme.C_TEXT_M)
		y += LANE_H + LANE_GAP
	_draw_axis(pr, font)
	_draw_hover(pr, font)


func _draw_series(r: Rect2, b: Dictionary, lo: float, hi: float, col: Color, band: bool) -> void:
	var w := float(b["w"])
	var i0 := int(b["i0"])
	var me: PackedFloat32Array = b["mean"]
	var mn: PackedFloat32Array = b["mn"]
	var mx: PackedFloat32Array = b["mx"]
	var px_per_h := r.size.x / (_span[1] - _span[0])
	var run := PackedVector2Array()
	for k in me.size() + 1:
		var known := k < me.size() and not is_nan(me[k])
		if known:
			var x := r.position.x + ((float(i0 + k) + 0.5) * w - _span[0]) * px_per_h
			if x < r.position.x - 1.0 or x > r.end.x + 1.0:
				known = false
			else:
				if band:
					var ya := _y(mx[k], lo, hi, r)
					var yb := _y(mn[k], lo, hi, r)
					draw_line(Vector2(x, ya), Vector2(x, maxf(yb, ya + 1.0)), Color(col, 0.28),
						maxf(px_per_h * w, 1.0))
				run.append(Vector2(x, _y(me[k], lo, hi, r)))
				continue
		if run.size() >= 2:
			draw_polyline(run, Color(col, 0.95), 1.6, true)
		elif run.size() == 1:
			draw_circle(run[0], 1.5, col)
		run = PackedVector2Array()


func _draw_axis(pr: Rect2, font: Font) -> void:
	var span := _span[1] - _span[0]
	var day0 := SiteTime.day_start(_span[0])
	var stride := 24.0 if span <= 24.0 * 16.0 else 24.0 * 7.0
	var tick_h := 6.0 if span <= 30.0 else (stride if span > 24.0 * 3.0 else 6.0)
	var t := day0
	var y := pr.end.y
	while t <= _span[1] + 1e-6:
		if t >= _span[0] - 1e-6:
			var x := pr.position.x + (t - _span[0]) / span * pr.size.x
			var is_day := absf(fposmod(t, 24.0)) < 1e-6
			draw_line(Vector2(x, 0.0), Vector2(x, y), Color(UITheme.C_BORDER, 0.55 if is_day else 0.25), 1.0)
			var txt := ""
			if _clock != null:
				var d: Dictionary = _clock.call("abs_hours_to_date", t)
				txt = "%d/%d" % [int(d["month"]), int(d["day"])] if is_day else "%02d:00" % int(round(float(d["day_time"])))
			draw_string(font, Vector2(x + 2.0, y + 13.0), txt, HORIZONTAL_ALIGNMENT_LEFT, -1,
				UITheme.FONT_XS, UITheme.C_TEXT_S)
		t += tick_h


func _draw_hover(pr: Rect2, font: Font) -> void:
	if _hover_x < pr.position.x or _hover_x > pr.end.x:
		return
	var t := _span[0] + (_hover_x - pr.position.x) / pr.size.x * (_span[1] - _span[0])
	draw_line(Vector2(_hover_x, 0.0), Vector2(_hover_x, pr.end.y), Color(UITheme.C_TEXT, 0.5), 1.0)
	var y := 0.0
	for lane in LANES:
		var ch := str(lane["ch"])
		var lines: Array = []
		for it in _items:
			var s: ExperimentSeries = it["series"]
			if not s.has(ch):
				continue
			var v := s.value_at(ch, t)
			lines.append([("%s %s" % [_fmt(v), str(lane["unit"])]) if not is_nan(v) else "—", it["color"]])
		var bx := _hover_x + 8.0
		if bx + 90.0 > pr.end.x:
			bx = _hover_x - 98.0
		var by := y + 14.0
		if not lines.is_empty():
			draw_rect(Rect2(bx - 4.0, y + 3.0, 92.0, 13.0 * lines.size() + 4.0),
				Color(UITheme.C_BG, 0.82), true)
		for ln in lines:
			draw_string(font, Vector2(bx, by), str(ln[0]), HORIZONTAL_ALIGNMENT_LEFT, 90, UITheme.FONT_XS, ln[1])
			by += 13.0
		y += LANE_H + LANE_GAP
	if _clock != null:
		var txt := SiteTime.format_abs(_clock, t)
		var tw := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_XS).x
		var tx := clampf(_hover_x - tw * 0.5, pr.position.x, pr.end.x - tw)
		draw_rect(Rect2(tx - 4.0, pr.end.y + 1.0, tw + 8.0, AXIS_H - 1.0), UITheme.C_PANEL, true)
		draw_string(font, Vector2(tx, pr.end.y + 13.0), txt, HORIZONTAL_ALIGNMENT_LEFT, -1,
			UITheme.FONT_XS, UITheme.C_TEXT)


static func _y(v: float, lo: float, hi: float, r: Rect2) -> float:
	return r.end.y - 3.0 - clampf((v - lo) / maxf(hi - lo, 1e-6), 0.0, 1.0) * (r.size.y - 6.0)


static func _fmt(v: float) -> String:
	if is_nan(v):
		return "—"
	if absf(v) >= 10.0:
		return "%.0f" % v
	return "%.1f" % v if absf(v) >= 1.0 else "%.2f" % v
