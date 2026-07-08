class_name ResourceEdgeVis
extends RefCounted

## Sankey-style stroke sizing and flow animation for typed resource graph edges.
## Colors and reference rates come from ResourceKinds — extend kinds there, not here.

const WIDTH_IDLE := 1.5
const WIDTH_MIN_ACTIVE := 2.4
const WIDTH_MAX := 12.0
const IDLE_SATURATION := 0.38
const IDLE_ALPHA := 0.30
const ACTIVE_ALPHA_FLOOR := 0.78
const FLOW_DEAD_RATE := 0.001
const DASH_COUNT := 14
const DASH_ON_FRAC := 0.52


## Returns {color, width, active, rate, rate_norm, kind}.
static func stroke_for(kind: String, rate: float, active: bool, selected: bool = false) -> Dictionary:
	var base: Color = ResourceKinds.wire_color(kind)
	var ref: float = ResourceKinds.flow_ref_rate(kind)
	var live: bool = active and rate > FLOW_DEAD_RATE
	var rate_norm: float = clampf(rate / maxf(ref, 0.0001), 0.0, 1.0) if live else 0.0
	var width: float = WIDTH_IDLE
	if live:
		width = lerpf(WIDTH_MIN_ACTIVE, WIDTH_MAX, pow(rate_norm, 0.58))
	if selected:
		width += 1.8
	var col: Color = base
	if live:
		col.a = lerpf(ACTIVE_ALPHA_FLOOR, 1.0, rate_norm)
	else:
		col = _desaturate(base, IDLE_SATURATION, IDLE_ALPHA)
	return {
		"color": col,
		"width": width,
		"active": live,
		"rate": rate,
		"rate_norm": rate_norm,
		"kind": kind,
	}


static func _desaturate(c: Color, sat: float, alpha: float) -> Color:
	var grey: float = (c.r + c.g + c.b) / 3.0
	return Color(
		lerpf(grey, c.r, sat),
		lerpf(grey, c.g, sat),
		lerpf(grey, c.b, sat),
		alpha)


## Animated direction cue: scrolling dashes along a cubic bezier (source → target).
static func draw_bezier_flow_cues(
		canvas: CanvasItem,
		from: Vector2, c1: Vector2, c2: Vector2, to: Vector2,
		col: Color, width: float, phase: float, reverse: bool) -> void:
	if width < 0.5:
		return
	const STEPS := 64
	var dash_len: float = 1.0 / float(DASH_COUNT)
	var scroll: float = fmod(phase * 0.42, dash_len)
	if reverse:
		scroll = -scroll
	var prev: Vector2 = from
	var prev_on: bool = false
	for i in range(1, STEPS + 1):
		var t: float = float(i) / float(STEPS)
		var p: Vector2 = from.bezier_interpolate(c1, c2, to, t)
		var u: float = t + scroll
		var on: bool = fmod(u + 1000.0, dash_len) < dash_len * DASH_ON_FRAC
		if on and prev_on:
			var w: float = maxf(1.2, width * 0.55)
			canvas.draw_line(prev, p, Color(col.r, col.g, col.b, col.a * 0.95), w)
			canvas.draw_line(prev, p, Color(1.0, 1.0, 1.0, col.a * 0.35), maxf(0.6, w * 0.35))
		prev = p
		prev_on = on


## Multi-segment path (waypoints) — samples via callback.
static func draw_path_flow_cues(
		canvas: CanvasItem,
		sample_fn: Callable,
		col: Color, width: float, phase: float, reverse: bool,
		steps_per_seg: int = 32) -> void:
	const PATH_STEPS := 48
	var total_len := 0.0
	var lengths: Array = [0.0]
	for i in range(1, PATH_STEPS + 1):
		var t0: float = float(i - 1) / float(PATH_STEPS)
		var t1: float = float(i) / float(PATH_STEPS)
		var p0: Vector2 = sample_fn.call(t0)
		var p1: Vector2 = sample_fn.call(t1)
		total_len += p0.distance_to(p1)
		lengths.append(total_len)
	if total_len < 1.0:
		return
	var dash_len: float = total_len / float(DASH_COUNT)
	var scroll: float = fmod(phase * 42.0, dash_len)
	if reverse:
		scroll = -scroll
	var prev: Vector2 = sample_fn.call(0.0)
	var prev_on: bool = false
	for i in range(1, PATH_STEPS + 1):
		var t: float = float(i) / float(PATH_STEPS)
		var p: Vector2 = sample_fn.call(t)
		var dist: float = lengths[i]
		var on: bool = fmod(dist + scroll + 10000.0, dash_len) < dash_len * DASH_ON_FRAC
		if on and prev_on:
			var w: float = maxf(1.2, width * 0.55)
			canvas.draw_line(prev, p, Color(col.r, col.g, col.b, col.a * 0.95), w)
		prev = p
		prev_on = on
