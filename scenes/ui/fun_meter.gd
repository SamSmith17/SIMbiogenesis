extends Control

## The FUN METER — the festival's Overall Vibe as a needle gauge.
##
## A half-dial from FUCK THIS!!! (left) to FUCK YES!!! (right): the six
## NpcMorale bands in their own colours (reds -> yellows -> greens, each band
## as wide as its morale range) across the first ZONE_FY of the arc, and the
## last stretch is the FUCK YES zone — reached only when people are actually
## PEAKING, not merely happy. The needle reads:
##   pos = lerp(mean morale x ZONE_FY, 1, min(peaking share / FULL_PEAK_SHARE, 1))
## i.e. the crowd's mean mood, pushed up into the green zone by the share of
## it at FUCK YES (a quarter of the crowd peaking pins it). It swings on a
## damped spring (a little overshoot reads as a live instrument), shivers
## faintly while people are peaking, and the zone pulses when the needle is in
## it. Under the dial: the state in words in its colour, then the score with
## its trend arrow and "N peaking of M".
##
## Data: SystemGraphView.festival_vibe() (camps), else FestivalVibe over the
## bridge's vibe_summaries() (any population), peaks from peak_score(). Polls
## at 2 Hz; the needle animates every frame. Drag it anywhere (the position
## is saved, NpcDisplayPrefs.fun_meter_pos); Settings -> NPCs turns it off.
## Visible only while people are simulated. Main creates it under UILayer.

const POLL_S := 0.5
const W := 236.0
const H := 178.0
const R := 84.0
const THICK := 15.0
const ZONE_FY := 0.86
const FULL_PEAK_SHARE := 0.25
const SPRING_K := 16.0
const SPRING_C := 5.5
const BG := Color(0.06, 0.07, 0.09, 0.9)
const FY_GREEN := Color(0.45, 1.0, 0.55)

var _accum := 0.0
var _score := NAN
var _target := 0.0
var _pos := 0.0
var _vel := 0.0
var _peaking := 0
var _people := 0
var _trend := 0.0
var _t := 0.0
var _has_data := false
var _dragging := false
var _drag_off := Vector2.ZERO
var _last_gen := -1


func _ready() -> void:
	custom_minimum_size = Vector2(W, H)
	size = Vector2(W, H)
	mouse_filter = Control.MOUSE_FILTER_STOP
	tooltip_text = "Fun Meter — the crowd's overall vibe. The needle is everyone's mean mood; people at FUCK YES!!! push it into the bright green zone. Drag to move; Settings → NPCs turns it off."
	visible = false
	_place()


func _place() -> void:
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	var p := NpcDisplayPrefs.fun_meter_pos()
	var vp := get_viewport_rect().size if is_inside_tree() else Vector2(1280, 720)
	if p.x < 0.0:
		p = Vector2(vp.x - W - 16.0, 64.0)
	position = _clamped(p)


func _clamped(p: Vector2) -> Vector2:
	var vp := get_viewport_rect().size if is_inside_tree() else Vector2(1280, 720)
	return Vector2(clampf(p.x, 0.0, maxf(vp.x - W, 0.0)), clampf(p.y, 0.0, maxf(vp.y - H, 0.0)))


func _process(delta: float) -> void:
	_t += delta
	_accum += delta
	var gen := NpcDisplayPrefs.generation()
	if gen != _last_gen:
		_last_gen = gen
		_place()
	if _accum >= POLL_S:
		_accum = 0.0
		_refresh()
	if not visible:
		return
	# Damped spring toward the target (a touch of overshoot), plus a faint
	# shiver while people are peaking.
	var acc := (_target - _pos) * SPRING_K - _vel * SPRING_C
	_vel += acc * minf(delta, 0.05)
	_pos += _vel * minf(delta, 0.05)
	queue_redraw()


func _refresh() -> void:
	var b := _bridge()
	if not NpcDisplayPrefs.fun_meter() or not NpcDisplayPrefs.npcs_enabled() \
			or b == null or not bool(b.call("active")):
		visible = false
		return
	var v: Dictionary = {}
	var sgv := _sgv()
	if sgv != null and sgv.has_method("festival_vibe"):
		v = sgv.call("festival_vibe")
	if v.is_empty() or int(v.get("people", 0)) <= 0:
		if b.has_method("vibe_summaries"):
			v = FestivalVibe.compute(b.call("vibe_summaries"))
	_people = int(v.get("people", 0))
	if _people <= 0:
		visible = false
		return
	var ps: Dictionary = b.call("peak_score") if b.has_method("peak_score") else {}
	_peaking = int(ps.get("now", 0))
	_score = float(v.get("score", 0.0))
	_trend = float(v.get("trend", 0.0))
	_target = needle_for(_score, float(_peaking) / float(_people))
	if not _has_data:
		_pos = _target   # first reading: no swing in from zero
		_has_data = true
	visible = true


## Where the needle points (0 = FUCK THIS!!!, 1 = FUCK YES!!!) for a mean
## morale and the share of people peaking.
static func needle_for(mean_morale: float, peak_share: float) -> float:
	var base := clampf(mean_morale, 0.0, 1.0) * ZONE_FY
	return lerpf(base, 1.0, clampf(peak_share / FULL_PEAK_SHARE, 0.0, 1.0))


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, Vector2(W, H))
	draw_style_box(UITheme.panel_style(0.92), rect)
	var c := Vector2(W * 0.5, 34.0 + R)
	var font := get_theme_default_font()
	# Title.
	draw_string(font, Vector2(0.0, 16.0), "FUN METER", HORIZONTAL_ALIGNMENT_CENTER, W, 11,
		Color(0.75, 0.8, 0.85, 0.9))
	# The bands, each as wide as its morale range.
	for band in NpcMorale.BANDS:
		var bd: Dictionary = band
		var lo := float(bd["min"])
		var hi := 1.0
		for other in NpcMorale.BANDS:
			var om := float((other as Dictionary)["min"])
			if om > lo and om < hi:
				hi = om
		var col: Color = bd["color"]
		col.a = 0.9
		_arc(c, lo * ZONE_FY, hi * ZONE_FY, col)
	# The FUCK YES zone, pulsing when the needle is in it.
	var in_fy := _pos >= ZONE_FY
	var pulse := 0.65 + 0.35 * sin(_t * 5.0) if in_fy else 0.75
	var fy := FY_GREEN.lightened(0.15 if in_fy else 0.0)
	fy.a = pulse
	_arc(c, ZONE_FY, 1.0, fy)
	if in_fy:
		# A glow round the zone.
		var g := FY_GREEN
		g.a = 0.18 * pulse
		draw_arc(c, R, _ang(ZONE_FY), _ang(1.0), 16, g, THICK + 10.0, true)
	# Ticks at the band edges.
	for band in NpcMorale.BANDS:
		var f := float((band as Dictionary)["min"]) * ZONE_FY
		if f <= 0.001:
			continue
		_tick(c, f, Color(0.04, 0.05, 0.06, 0.95))
	_tick(c, ZONE_FY, Color(0.9, 1.0, 0.9, 0.95))
	# End labels.
	draw_string(font, c + Vector2(-R - 4.0, 16.0), "FUCK THIS", HORIZONTAL_ALIGNMENT_LEFT, -1, 9,
		Color(0.93, 0.45, 0.4, 0.9))
	draw_string(font, c + Vector2(R - 46.0, 16.0), "FUCK YES", HORIZONTAL_ALIGNMENT_LEFT, -1, 9,
		FY_GREEN)
	# The needle (with a shiver while anyone peaks).
	var shiver := sin(_t * 31.0) * 0.004 * clampf(float(_peaking) / 10.0, 0.0, 1.0)
	var a := _ang(clampf(_pos + shiver, -0.02, 1.02))
	var tip := c + Vector2(cos(a), sin(a)) * (R + THICK * 0.4)
	var tail := c - Vector2(cos(a), sin(a)) * 10.0
	draw_line(tail, tip, Color(0.0, 0.0, 0.0, 0.6), 5.0, true)
	draw_line(tail, tip, Color(1.0, 1.0, 1.0, 0.95), 2.5, true)
	draw_circle(c, 6.0, Color(0.9, 0.92, 0.95))
	draw_circle(c, 3.0, Color(0.15, 0.17, 0.2))
	# The state in words, in its colour; then the numbers.
	var label := NpcPeak.LABEL if in_fy else NpcMorale.label(_score if not is_nan(_score) else 0.0)
	var lc: Color = FY_GREEN if in_fy else NpcMorale.color(_score if not is_nan(_score) else 0.0)
	draw_string_outline(font, Vector2(0.0, c.y + 30.0), label, HORIZONTAL_ALIGNMENT_CENTER, W, 17, 4,
		Color(0.0, 0.0, 0.0, 0.85))
	draw_string(font, Vector2(0.0, c.y + 30.0), label, HORIZONTAL_ALIGNMENT_CENTER, W, 17, lc)
	var arrow := "▲" if _trend > FestivalVibe.TREND_EPS else ("▼" if _trend < -FestivalVibe.TREND_EPS else "")
	var sub := "%.2f %s  ·  %d peaking of %d" % [_score if not is_nan(_score) else 0.0, arrow, _peaking, _people]
	draw_string(font, Vector2(0.0, c.y + 47.0), sub, HORIZONTAL_ALIGNMENT_CENTER, W, 11,
		Color(0.8, 0.85, 0.9, 0.9))


func _ang(f: float) -> float:
	return PI + clampf(f, -0.05, 1.05) * PI


func _arc(c: Vector2, f0: float, f1: float, col: Color) -> void:
	if f1 <= f0:
		return
	var segs := maxi(int((f1 - f0) * 64.0), 3)
	draw_arc(c, R, _ang(f0), _ang(f1), segs, col, THICK, true)


func _tick(c: Vector2, f: float, col: Color) -> void:
	var a := _ang(f)
	var d := Vector2(cos(a), sin(a))
	draw_line(c + d * (R - THICK * 0.5 - 1.0), c + d * (R + THICK * 0.5 + 1.0), col, 2.0, true)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		_dragging = mb.pressed
		_drag_off = mb.position
		if not mb.pressed:
			NpcDisplayPrefs.set_fun_meter_pos(position)
		accept_event()
	elif event is InputEventMouseMotion and _dragging:
		position = _clamped(position + (event as InputEventMouseMotion).position - _drag_off)
		accept_event()


func _sgv() -> Node:
	var scene := get_tree().current_scene if get_tree() != null else null
	return scene.get_node_or_null("UILayer/SystemGraphView") if scene != null else null


func _bridge() -> Object:
	var sgv := _sgv()
	if sgv == null or not sgv.has_method("npc_population_bridge"):
		return null
	return sgv.call("npc_population_bridge")
