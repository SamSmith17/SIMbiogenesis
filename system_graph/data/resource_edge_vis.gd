class_name ResourceEdgeVis
extends RefCounted

## Sankey-style stroke sizing and flow animation for typed resource graph edges.
## Colors and reference rates come from ResourceKinds — extend kinds there, not here.

const WIDTH_IDLE := 2.8
const WIDTH_MIN_ACTIVE := 4.5
const WIDTH_MAX := 14.0
const IDLE_SATURATION := 0.48
const IDLE_ALPHA := 0.42
const ACTIVE_ALPHA_FLOOR := 0.82
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
		"glow_scale": glow_scale(kind, rate, live),
	}


## Normalized 0..1 intensity for resource-wire glow (mirrors power Sankey curve).
static func glow_scale(kind: String, rate: float, active: bool) -> float:
	if not active or rate <= FLOW_DEAD_RATE:
		return 0.0
	var ref: float = maxf(ResourceKinds.flow_ref_rate(kind), 0.0001)
	var t: float = clampf(rate / ref, 0.0, 1.2)
	return pow(t, 0.58)


## Screen-space body width from Sankey width + flow intensity.
static func body_width(base_width: float, gscale: float) -> float:
	return maxf(2.4, base_width + 0.45 + gscale * 1.15)


static func _desaturate(c: Color, sat: float, alpha: float) -> Color:
	var grey: float = (c.r + c.g + c.b) / 3.0
	return Color(
		lerpf(grey, c.r, sat),
		lerpf(grey, c.g, sat),
		lerpf(grey, c.b, sat),
		alpha)


## Animated direction cue: scrolling dashes along a cubic bezier (source → target).
## `steps` defaults to 64; pass ~28 under high-speed / wire LOD.
static func draw_bezier_flow_cues(
		canvas: CanvasItem,
		from: Vector2, c1: Vector2, c2: Vector2, to: Vector2,
		col: Color, width: float, phase: float, reverse: bool,
		steps: int = 64) -> void:
	if width < 0.5:
		return
	var step_n := maxi(8, steps)
	var dash_len: float = 1.0 / float(DASH_COUNT)
	var scroll: float = fmod(phase * 0.42, dash_len)
	if reverse:
		scroll = -scroll
	var prev: Vector2 = from
	var prev_on: bool = false
	for i in range(1, step_n + 1):
		var t: float = float(i) / float(step_n)
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


const FLOW_ARROW_ALPHA := 0.82


## Directional flow arrow at bezier parameter t (shared by power + resource wires).
static func draw_bezier_flow_arrow(
		canvas: CanvasItem,
		from: Vector2, c1: Vector2, c2: Vector2, to: Vector2,
		t: float, col: Color, body_w: float, reverse: bool,
		gscale: float = 0.5) -> void:
	var p := from.bezier_interpolate(c1, c2, to, t)
	var dt := 0.018 if not reverse else -0.018
	var t2 := clampf(t + dt, 0.0, 1.0)
	var p2 := from.bezier_interpolate(c1, c2, to, t2)
	_draw_arrow_at(canvas, p, p2, col, body_w, gscale)


## Directional flow arrow along an arbitrary sample_fn(t) → Vector2 path.
static func draw_sample_flow_arrow(
		canvas: CanvasItem,
		sample_fn: Callable,
		t: float, col: Color, body_w: float, reverse: bool,
		gscale: float = 0.5) -> void:
	var dt := 0.012 if not reverse else -0.012
	var t0 := clampf(t, 0.0, 1.0)
	var t1 := clampf(t + dt, 0.0, 1.0)
	var p: Vector2 = sample_fn.call(t0) as Vector2
	var p2: Vector2 = sample_fn.call(t1) as Vector2
	_draw_arrow_at(canvas, p, p2, col, body_w, gscale)


## Scatter several arrows along a bezier (count scales with gscale).
static func draw_bezier_flow_arrows(
		canvas: CanvasItem,
		from: Vector2, c1: Vector2, c2: Vector2, to: Vector2,
		col: Color, body_w: float, phase: float, reverse: bool,
		gscale: float) -> void:
	var arrow_count := 2 + int(gscale * 3.0)
	var arrow_gap := maxf(0.12, 0.22 - gscale * 0.07)
	var arrow_t := fposmod(phase * 0.27, 1.0)
	if reverse:
		arrow_t = 1.0 - arrow_t
	for i in arrow_count:
		var t := fposmod(arrow_t + float(i) * arrow_gap, 1.0)
		draw_bezier_flow_arrow(canvas, from, c1, c2, to, t, col, body_w, reverse, gscale)


static func draw_sample_flow_arrows(
		canvas: CanvasItem,
		sample_fn: Callable,
		col: Color, body_w: float, phase: float, reverse: bool,
		gscale: float) -> void:
	var arrow_count := 2 + int(gscale * 3.0)
	var arrow_gap := maxf(0.12, 0.22 - gscale * 0.07)
	var arrow_t := fposmod(phase * 0.27, 1.0)
	if reverse:
		arrow_t = 1.0 - arrow_t
	for i in arrow_count:
		var t := fposmod(arrow_t + float(i) * arrow_gap, 1.0)
		draw_sample_flow_arrow(canvas, sample_fn, t, col, body_w, reverse, gscale)


static func _draw_arrow_at(canvas: CanvasItem, p: Vector2, p2: Vector2,
		col: Color, body_w: float, gscale: float) -> void:
	var dir := (p2 - p).normalized()
	if dir.length_squared() < 0.0001:
		return
	var side := Vector2(-dir.y, dir.x)
	var sz := 1.0 + gscale * 0.7
	var len := maxf(5.0, body_w * 1.85 * sz)
	var wid := maxf(2.5, body_w * 0.75 * sz)
	var a := p + dir * len
	var b := p - dir * len * 0.55 + side * wid
	var c := p - dir * len * 0.55 - side * wid
	canvas.draw_colored_polygon(PackedVector2Array([a, b, c]),
			Color(1.0, 1.0, 1.0, FLOW_ARROW_ALPHA * (0.7 + gscale * 0.3)))
	canvas.draw_colored_polygon(PackedVector2Array([p + dir * (len * 0.70), b, c]),
			Color(col.r, col.g, col.b, 0.60 + gscale * 0.25))
