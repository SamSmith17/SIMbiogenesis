class_name MimicSymbols
extends RefCounted
## The drawing library of the process picture (plans/SCADA_PROCESS_PLAN.md,
## Phase 2): shaded pipes with moving flow, tanks with their contents,
## valves, heaters, instruments, open ends. Everything is drawn in SCREEN
## pixels on a CanvasItem; nothing here knows where its numbers come from.
##
## Look: the game's dark theme, steel lit from the top-left, contents in
## colour. Colour means something: what is inside (temperature for gas, blue
## for liquid), green = open / running, grey = closed / off, amber = warning.
##
## No draw_circle / draw_style_box: GraphFastDraw's cached discs and
## rounded rects, polylines and polygons.

const BG := Color(0.043, 0.059, 0.098)
const GRID := Color(0.16, 0.20, 0.28, 0.35)
const STEEL := Color(0.36, 0.40, 0.47)
const STEEL_DARK := Color(0.13, 0.15, 0.19)
const STEEL_LIGHT := Color(0.74, 0.78, 0.84)
const EMPTY := Color(0.10, 0.12, 0.16)
const LIQUID := Color(0.22, 0.56, 0.96)
const COOLANT := Color(0.20, 0.42, 0.70)
const OPEN := Color(0.30, 0.86, 0.52)
const CLOSED := Color(0.52, 0.56, 0.63)
const WARN := Color(0.98, 0.70, 0.22)
const HOT := Color(1.0, 0.38, 0.14)
const TEXT := Color(0.886, 0.910, 0.941)
const TEXT_DIM := Color(0.58, 0.63, 0.72)
const SELECT := Color(0.36, 0.80, 1.0)
const TAG_BG := Color(0.07, 0.09, 0.14, 0.92)


## What a gas at `t_c` looks like in a pipe or headspace: dark and cool
## when cold, amber by the boiling point, red hot, near white past 700 °C.
static func heat_rgb(t_c: float) -> Color:
	var stops := [[15.0, Color(0.20, 0.27, 0.40)], [60.0, Color(0.24, 0.52, 0.72)], [100.0, Color(0.86, 0.72, 0.30)],
		[250.0, Color(0.95, 0.52, 0.18)], [450.0, Color(0.96, 0.26, 0.12)], [700.0, Color(1.0, 0.82, 0.70)]]
	if t_c <= float(stops[0][0]):
		return stops[0][1]
	for i in range(1, stops.size()):
		if t_c <= float(stops[i][0]):
			var a := float(stops[i - 1][0])
			var b := float(stops[i][0])
			return (stops[i - 1][1] as Color).lerp(stops[i][1], (t_c - a) / (b - a))
	return stops[stops.size() - 1][1]


static func _offset(pts: PackedVector2Array, off: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(pts.size())
	for i in pts.size():
		out[i] = pts[i] + off
	return out


static func _line(ci: CanvasItem, pts: PackedVector2Array, col: Color, w: float) -> void:
	if pts.size() < 2:
		return
	ci.draw_polyline(pts, col, w, w >= 2.0)
	if w >= 5.0:
		# Round the ends and the corners (a wide polyline has neither).
		GraphFastDraw.disc(ci, pts[0], w * 0.5, col)
		GraphFastDraw.disc(ci, pts[pts.size() - 1], w * 0.5, col)


## A pipe along `pts` (screen), `w` px across. `o`: fill (the contents'
## colour, EMPTY when nothing), level 0..1 (liquid share: the lower part of
## the bore is drawn LIQUID), shell (a cooling jacket's colour; alpha 0 =
## none), flow (-1 / 0 / +1 along the points), phase (px the flow marks have
## moved), selected, hover.
static func pipe(ci: CanvasItem, pts: PackedVector2Array, w: float, o: Dictionary) -> void:
	if pts.size() < 2:
		return
	var shell: Color = o.get("shell", Color(0, 0, 0, 0))
	if shell.a > 0.0:
		_line(ci, pts, STEEL_DARK, w * 2.0 + 2.0)
		_line(ci, pts, shell.darkened(0.25), w * 2.0)
		_line(ci, pts, shell, w * 1.7)
	if bool(o.get("selected", false)) or bool(o.get("hover", false)):
		_line(ci, pts, Color(SELECT, 0.85 if bool(o.get("selected", false)) else 0.4), w + 6.0)
	# A tube: dark edge, steel, a lighter band toward the middle (the same
	# whichever way the pipe runs), then the bore with what is in it.
	var jacket: Color = o.get("service", Color(0, 0, 0, 0))
	_line(ci, pts, STEEL_DARK, w + 2.0)
	if jacket.a > 0.0:
		# The service's colour on the outside, like painted / banded pipe.
		_line(ci, pts, jacket.darkened(0.35), w)
		if w >= 4.0:
			_line(ci, pts, jacket.darkened(0.05), w * 0.80)
	else:
		_line(ci, pts, STEEL.darkened(0.18), w)
		if w >= 4.0:
			_line(ci, pts, STEEL.lightened(0.22), w * 0.80)
	var bore := maxf(w * 0.56, 1.0)
	var fill: Color = o.get("fill", EMPTY)
	_line(ci, pts, fill, bore)
	var level := float(o.get("level", 0.0))
	if level > 0.02 and w >= 3.0:
		_line(ci, pts, LIQUID, bore * clampf(level, 0.18, 1.0))
	var flow := int(o.get("flow", 0))
	if flow != 0 and w >= 3.0:
		_flow_marks(ci, pts, bore, flow, float(o.get("phase", 0.0)), fill.lightened(0.55))


## Short bright marks moving along the bore: one pass over the points.
static func _flow_marks(ci: CanvasItem, pts: PackedVector2Array, bore: float, flow: int, phase: float, col: Color) -> void:
	var period := maxf(bore * 3.4, 18.0)
	var mark := period * 0.34
	var next := fposmod(phase, period)
	if flow < 0:
		next = period - next
	var w := maxf(bore * 0.36, 1.0)
	var walked := 0.0
	var lines := PackedVector2Array()
	for i in range(1, pts.size()):
		var a := pts[i - 1]
		var seg := a.distance_to(pts[i])
		if seg < 1e-4:
			continue
		var d := (pts[i] - a) / seg
		while next < walked + seg:
			var s0 := next - walked
			lines.append(a + d * s0)
			lines.append(a + d * minf(s0 + mark, seg))
			next += period
			if lines.size() > 600:
				break
		walked += seg
	if lines.size() >= 2:
		ci.draw_multiline(lines, col, w, true)


static func _vgrad(ci: CanvasItem, r: Rect2, base: Color) -> void:
	# A cylinder lit from the left: three bands.
	ci.draw_rect(r, base)
	ci.draw_rect(Rect2(r.position.x + r.size.x * 0.10, r.position.y, r.size.x * 0.16, r.size.y), Color(base.lightened(0.38), 0.75))
	ci.draw_rect(Rect2(r.position.x + r.size.x * 0.74, r.position.y, r.size.x * 0.26, r.size.y), Color(base.darkened(0.35), 0.65))


static func _dome(ci: CanvasItem, top_centre: Vector2, half_w: float, h: float, col: Color, down: bool = false) -> void:
	var pts := PackedVector2Array()
	var n := 14
	for i in n + 1:
		var a := PI * float(i) / float(n)
		pts.append(top_centre + Vector2(-cos(a) * half_w, (sin(a) * h) * (1.0 if down else -1.0)))
	ci.draw_colored_polygon(pts, col)


## A vessel. `r` = the shell (screen). `o`: jacket (bool), jacket_col, lid
## (bool), gas (headspace colour), level 0..1 (liquid from the bottom),
## bed {h 0..1 of the shell, col, glow 0..1} or {}, selected, hover.
static func vessel(ci: CanvasItem, r: Rect2, o: Dictionary) -> void:
	var dome_h := float(o.get("dome_h", minf(r.size.x * 0.16, r.size.y * 0.18)))
	if bool(o.get("jacket", false)):
		var j := r.grow_individual(r.size.x * 0.08, 0.0, r.size.x * 0.08, r.size.x * 0.10)
		var jc: Color = o.get("jacket_col", STEEL.darkened(0.25))
		_vgrad(ci, j, jc)
		ci.draw_rect(j, STEEL_DARK, false, 1.5)
	if bool(o.get("selected", false)) or bool(o.get("hover", false)):
		ci.draw_rect(r.grow(4.0), Color(SELECT, 0.85 if bool(o.get("selected", false)) else 0.4), false, 3.0)
	if bool(o.get("lid", true)) and dome_h > 1.0:
		_dome(ci, Vector2(r.get_center().x, r.position.y), r.size.x * 0.5, dome_h, STEEL)
		_dome(ci, Vector2(r.get_center().x - r.size.x * 0.16, r.position.y), r.size.x * 0.22, dome_h * 0.8, Color(STEEL.lightened(0.3), 0.5))
	_vgrad(ci, r, STEEL)
	# The inside, seen through a window in the shell.
	var win := r.grow_individual(-r.size.x * 0.13, -r.size.y * 0.035, -r.size.x * 0.13, -r.size.y * 0.035)
	ci.draw_rect(win, o.get("gas", EMPTY))
	var bed: Dictionary = o.get("bed", {})
	var floor_y := win.end.y
	if not bed.is_empty():
		var bh := win.size.y * clampf(float(bed.get("h", 0.0)), 0.0, 1.0)
		var br := Rect2(win.position.x, floor_y - bh, win.size.x, bh)
		ci.draw_rect(br, bed.get("col", Color(0.5, 0.38, 0.22)))
		var glow := float(bed.get("glow", 0.0))
		if glow > 0.01:
			ci.draw_rect(br, Color(HOT, 0.55 * glow))
		# A rough top so it reads as a heap of pieces, not a liquid.
		var x := br.position.x
		var step := maxf(br.size.x / 14.0, 3.0)
		var k := 0
		while x < br.end.x - 0.5:
			var hh := step * (0.35 if k % 2 == 0 else 0.6)
			ci.draw_rect(Rect2(x, br.position.y - hh, minf(step, br.end.x - x), hh), bed.get("col", Color(0.5, 0.38, 0.22)))
			x += step
			k += 1
	var level := clampf(float(o.get("level", 0.0)), 0.0, 1.0)
	var liquid: Color = o.get("liquid", LIQUID)
	if level > 0.005:
		var lh := win.size.y * level
		ci.draw_rect(Rect2(win.position.x, floor_y - lh, win.size.x, lh), Color(liquid, 0.80 if bed.is_empty() else 0.45))
		ci.draw_line(Vector2(win.position.x, floor_y - lh), Vector2(win.end.x, floor_y - lh), liquid.lightened(0.5), 1.5)
	if bool(o.get("ticks", false)) and win.size.y > 60.0:
		# A level scale down the window's side: quarters.
		for q in [0.25, 0.5, 0.75]:
			var ty: float = floor_y - win.size.y * float(q)
			ci.draw_line(Vector2(win.position.x, ty), Vector2(win.position.x + win.size.x * 0.12, ty), Color(STEEL_LIGHT, 0.6), 1.0)
	ci.draw_rect(win, STEEL_DARK, false, 1.5)
	ci.draw_rect(r, STEEL_DARK, false, 1.5)


## A water-sealed gas holder: a tank with a bell that rises as it fills.
static func holder(ci: CanvasItem, r: Rect2, fill: float, sel: bool, hover: bool) -> void:
	_frame(ci, r, sel, hover)
	var tank := Rect2(r.position.x, r.position.y + r.size.y * 0.42, r.size.x, r.size.y * 0.58)
	var bell_w := r.size.x * 0.74
	var travel := r.size.y * 0.36
	var by := tank.position.y - travel * clampf(fill, 0.0, 1.0) - r.size.y * 0.04
	var bell := Rect2(r.get_center().x - bell_w * 0.5, by, bell_w, r.size.y * 0.46)
	_vgrad(ci, bell, Color(0.30, 0.46, 0.70))
	_dome(ci, Vector2(bell.get_center().x, bell.position.y), bell_w * 0.5, bell_w * 0.12, Color(0.30, 0.46, 0.70))
	ci.draw_rect(bell, STEEL_DARK, false, 1.5)
	_vgrad(ci, tank, Color(0.22, 0.34, 0.54))
	ci.draw_rect(Rect2(tank.position.x + 3, tank.position.y + 3, tank.size.x - 6, tank.size.y * 0.12), Color(LIQUID, 0.7))
	ci.draw_rect(tank, STEEL_DARK, false, 1.5)


## A generator set: an engine block with a shaft; `kw` > 0 lights it.
static func engine(ci: CanvasItem, r: Rect2, running: bool, sel: bool, hover: bool, phase: float) -> void:
	_frame(ci, r, sel, hover)
	var body := r.grow_individual(0, -r.size.y * 0.18, 0, 0)
	GraphFastDraw.rrect(ci, body, 5.0, Color(0.20, 0.42, 0.40) if running else STEEL.darkened(0.2))
	ci.draw_rect(Rect2(body.position.x + body.size.x * 0.08, body.position.y + body.size.y * 0.12, body.size.x * 0.84, body.size.y * 0.10),
		Color(1, 1, 1, 0.12))
	var c := Vector2(body.position.x + body.size.x * 0.30, body.get_center().y + body.size.y * 0.08)
	var rr := minf(body.size.x, body.size.y) * 0.24
	GraphFastDraw.disc(ci, c, rr, STEEL_DARK)
	GraphFastDraw.ring(ci, c, rr, STEEL_LIGHT, 1.5)
	var a := phase * 0.12 if running else 0.6
	for k in 3:
		var d := Vector2.from_angle(a + TAU * float(k) / 3.0) * rr * 0.8
		ci.draw_line(c, c + d, OPEN if running else CLOSED, 2.0, true)
	GraphFastDraw.rrect_border(ci, body, 5.0, STEEL_DARK, 1)
	# Exhaust.
	var ex := Rect2(body.position.x + body.size.x * 0.72, r.position.y, body.size.x * 0.10, r.size.y * 0.20)
	ci.draw_rect(ex, STEEL_DARK)


## A desiccant column: a tube of beads that colours as it loads.
static func dryer(ci: CanvasItem, r: Rect2, fill: float, sel: bool, hover: bool) -> void:
	_frame(ci, r, sel, hover)
	var lying := r.size.x > r.size.y
	if lying:
		ci.draw_rect(r, STEEL)
		ci.draw_rect(Rect2(r.position.x, r.position.y + r.size.y * 0.10, r.size.x, r.size.y * 0.16), Color(STEEL.lightened(0.38), 0.75))
		ci.draw_rect(Rect2(r.position.x, r.position.y + r.size.y * 0.74, r.size.x, r.size.y * 0.26), Color(STEEL.darkened(0.35), 0.65))
	else:
		_vgrad(ci, r, STEEL)
	var win := r.grow_individual(-r.size.x * 0.2, -r.size.y * 0.06, -r.size.x * 0.2, -r.size.y * 0.06)
	if lying:
		win = r.grow_individual(-r.size.x * 0.06, -r.size.y * 0.2, -r.size.x * 0.06, -r.size.y * 0.2)
	ci.draw_rect(win, Color(0.86, 0.60, 0.20))
	if lying:
		# The gas comes in at one end: the used beads start there.
		ci.draw_rect(Rect2(win.position.x, win.position.y, win.size.x * clampf(fill, 0.0, 1.0), win.size.y), Color(0.30, 0.62, 0.50))
	else:
		var used := win.size.y * clampf(fill, 0.0, 1.0)
		ci.draw_rect(Rect2(win.position.x, win.end.y - used, win.size.x, used), Color(0.30, 0.62, 0.50))
	ci.draw_rect(win, STEEL_DARK, false, 1.0)
	ci.draw_rect(r, STEEL_DARK, false, 1.5)


## A flare stack; a flame while `kw` > 0.
static func flare(ci: CanvasItem, r: Rect2, kw: float, sel: bool, hover: bool, phase: float) -> void:
	_frame(ci, r, sel, hover)
	var stack := Rect2(r.get_center().x - r.size.x * 0.12, r.position.y + r.size.y * 0.3, r.size.x * 0.24, r.size.y * 0.7)
	_vgrad(ci, stack, STEEL)
	ci.draw_rect(stack, STEEL_DARK, false, 1.5)
	if kw > 0.01:
		var top := Vector2(stack.get_center().x, stack.position.y)
		var h := r.size.y * (0.22 + 0.06 * sin(phase * 0.2))
		var w := r.size.x * 0.22
		ci.draw_colored_polygon(PackedVector2Array([top + Vector2(-w, 0), top + Vector2(0, -h), top + Vector2(w, 0)]), HOT)
		ci.draw_colored_polygon(PackedVector2Array([top + Vector2(-w * 0.5, 0), top + Vector2(0, -h * 0.6), top + Vector2(w * 0.5, 0)]),
			Color(1.0, 0.86, 0.4))


## A machine: a shaded cabinet with a status lamp. `o`: accent (its stripe),
## running, warn, on (switched on), selected, hover.
static func machine(ci: CanvasItem, r: Rect2, o: Dictionary) -> void:
	_frame(ci, r, bool(o.get("selected", false)), bool(o.get("hover", false)))
	GraphFastDraw.rrect(ci, r, 8.0, STEEL.darkened(0.42))
	GraphFastDraw.rrect(ci, r.grow_individual(-2, -2, -2, -r.size.y * 0.5), 6.0, Color(1, 1, 1, 0.05))
	var accent: Color = o.get("accent", STEEL_LIGHT)
	ci.draw_rect(Rect2(r.position.x + 8.0, r.position.y + 8.0, r.size.x - 16.0, maxf(r.size.y * 0.06, 3.0)), accent)
	GraphFastDraw.rrect_border(ci, r, 8.0, STEEL_DARK.lightened(0.25), 1)
	# What it does, as a pictogram in the cabinet (below the reading).
	var gl: Variant = o.get("glyph", null)
	if gl is Texture2D:
		_pictogram(ci, r, gl as Texture2D, STEEL_LIGHT if bool(o.get("on", false)) or bool(o.get("running", false)) else STEEL.lightened(0.15))
	var lamp := CLOSED
	if bool(o.get("warn", false)):
		lamp = WARN
	elif bool(o.get("running", false)):
		lamp = OPEN
	elif bool(o.get("on", false)):
		lamp = Color(OPEN, 0.45)
	var lr := clampf(r.size.y * 0.07, 4.0, 11.0)
	var lc := Vector2(r.end.x - lr * 2.2, r.position.y + lr * 2.6 + r.size.y * 0.06)
	if bool(o.get("running", false)):
		GraphFastDraw.disc(ci, lc, lr * 1.9, Color(lamp, 0.22))
	GraphFastDraw.disc(ci, lc, lr, lamp)


## A pump: the diagram's circle with a triangle pointing the way it pushes;
## the triangle turns green and the ring glows while it moves water.
static func pump(ci: CanvasItem, r: Rect2, o: Dictionary) -> void:
	var c := r.get_center()
	var rad := minf(r.size.x, r.size.y) * 0.42
	if bool(o.get("selected", false)) or bool(o.get("hover", false)):
		GraphFastDraw.ring(ci, c, rad + 6.0, Color(SELECT, 0.9 if bool(o.get("selected", false)) else 0.45), 3.0)
	var running := bool(o.get("running", false))
	var col := OPEN if running else (WARN if bool(o.get("warn", false)) else (Color(OPEN, 0.5) if bool(o.get("on", false)) else CLOSED))
	# Feet.
	ci.draw_rect(Rect2(c.x - rad * 0.75, c.y + rad * 0.86, rad * 1.5, maxf(rad * 0.16, 2.0)), STEEL_DARK.lightened(0.2))
	if running:
		GraphFastDraw.disc(ci, c, rad * 1.22, Color(OPEN, 0.14))
	GraphFastDraw.disc(ci, c, rad, STEEL.darkened(0.3))
	GraphFastDraw.ring(ci, c, rad, STEEL_LIGHT, maxf(rad * 0.07, 1.5))
	var a := float(o.get("phase", 0.0)) * 0.1 if running else 0.0
	# The impeller's three vanes turn while it runs.
	for k in 3:
		var d := Vector2.from_angle(a + TAU * float(k) / 3.0) * rad * 0.62
		ci.draw_line(c, c + d, Color(col, 0.55), maxf(rad * 0.08, 1.5), true)
	var t := rad * 0.46
	ci.draw_colored_polygon(PackedVector2Array([c + Vector2(t, 0), c + Vector2(-t * 0.7, -t * 0.8), c + Vector2(-t * 0.7, t * 0.8)]), col)


## A pictogram centred in the lower part of a box (the reading is on top).
static func _pictogram(ci: CanvasItem, r: Rect2, tex: Texture2D, ink: Color) -> void:
	var side := minf(r.size.y * 0.46, r.size.x * 0.5)
	if side < 6.0:
		return
	var c := Vector2(r.get_center().x, r.position.y + r.size.y * 0.62)
	ci.draw_texture_rect(tex, Rect2(c - Vector2(side, side) * 0.5, Vector2(side, side)), false, ink)


## A piece of equipment drawn as a picture of itself (MimicIcons: flat grey
## tones and line work), fitted into `r` and standing on its bottom edge.
## State in colour only: a lamp, a ground line (green running, amber when
## something is wrong), the picture dimmed while it is off. `o`: selected,
## hover, running, warn, on, group (a dashed frame you go into), source.
static func equipment_icon(ci: CanvasItem, r: Rect2, tex: Texture2D, o: Dictionary) -> void:
	var sel := bool(o.get("selected", false))
	var hov := bool(o.get("hover", false))
	var running := bool(o.get("running", false))
	var warn := bool(o.get("warn", false))
	var on := bool(o.get("on", false)) or running
	if bool(o.get("group", false)):
		group(ci, r, sel, hov)
	elif sel or hov:
		GraphFastDraw.rrect_border(ci, r.grow(5.0), 10.0, Color(SELECT, 0.9 if sel else 0.45), 2)
	var ts := tex.get_size()
	if ts.x < 1.0 or ts.y < 1.0:
		return
	var box := r.grow(-6.0) if bool(o.get("group", false)) else r
	var k := minf(box.size.x / ts.x, box.size.y / ts.y)
	var dsz := ts * k
	var dr := Rect2(Vector2(box.get_center().x - dsz.x * 0.5, box.end.y - dsz.y), dsz)
	var state_col := WARN if warn else (OPEN if running else (Color(OPEN, 0.45) if on else CLOSED))
	if running and not warn:
		GraphFastDraw.rrect(ci, Rect2(dr.position.x, dr.end.y - 3.0, dr.size.x, 6.0), 3.0, Color(OPEN, 0.18))
	ci.draw_texture_rect(tex, dr, false, Color(1, 1, 1, 1.0 if on or bool(o.get("source", false)) else 0.62))
	# The ground it stands on, in its state's colour.
	var gy := dr.end.y + 2.0
	ci.draw_line(Vector2(dr.position.x - 4.0, gy), Vector2(dr.end.x + 4.0, gy), Color(state_col, 0.9 if running or warn else 0.55), 2.0, true)
	# The lamp at the picture's own top corner (a thin picture's box is wider).
	var lr := clampf(r.size.y * 0.06, 3.5, 9.0)
	var lc := Vector2(minf(dr.end.x + lr * 0.9, r.end.x + lr * 0.5), dr.position.y + lr * 0.4)
	if running or warn:
		GraphFastDraw.disc(ci, lc, lr * 1.9, Color(state_col, 0.22))
	GraphFastDraw.disc(ci, lc, lr, state_col)
	GraphFastDraw.ring(ci, lc, lr, BG, 1.5)


## A group of nodes (a compound): a dashed box you go into.
static func group(ci: CanvasItem, r: Rect2, sel: bool, hover: bool) -> void:
	_frame(ci, r, sel, hover)
	GraphFastDraw.rrect(ci, r, 10.0, Color(0.10, 0.13, 0.19, 0.9))
	var col := Color(STEEL_LIGHT, 0.7)
	var dash := 12.0
	var x := r.position.x
	while x < r.end.x:
		var x1 := minf(x + dash, r.end.x)
		ci.draw_line(Vector2(x, r.position.y), Vector2(x1, r.position.y), col, 1.5)
		ci.draw_line(Vector2(x, r.end.y), Vector2(x1, r.end.y), col, 1.5)
		x += dash * 2.0
	var y := r.position.y
	while y < r.end.y:
		var y1 := minf(y + dash, r.end.y)
		ci.draw_line(Vector2(r.position.x, y), Vector2(r.position.x, y1), col, 1.5)
		ci.draw_line(Vector2(r.end.x, y), Vector2(r.end.x, y1), col, 1.5)
		y += dash * 2.0


## A small shut valve on a store's inlet or outlet (its own built-in valve).
static func port_valve(ci: CanvasItem, c: Vector2, s: float, open: bool) -> void:
	valve(ci, c, s, Vector2.RIGHT, "valve", open, false, false)


static func _frame(ci: CanvasItem, r: Rect2, sel: bool, hover: bool) -> void:
	if sel or hover:
		ci.draw_rect(r.grow(4.0), Color(SELECT, 0.85 if sel else 0.4), false, 3.0)


## A valve at `c`, `s` px across, on a pipe running along `dir`. Two
## triangles tip to tip (the P&ID gate valve) with a stem and handle; green
## when open, grey when closed. `kind`: valve | check | relief.
static func valve(ci: CanvasItem, c: Vector2, s: float, dir: Vector2, kind: String, open: bool, sel: bool, hover: bool) -> void:
	var d := dir.normalized() if dir.length() > 0.01 else Vector2.RIGHT
	var n := Vector2(-d.y, d.x)
	if n.y > 0.0:
		n = -n   # the stem points up the page
	var h := s * 0.5
	var col := OPEN if open else CLOSED
	if sel or hover:
		GraphFastDraw.ring(ci, c, h * 1.5, Color(SELECT, 0.9 if sel else 0.45), 3.0)
	var a := PackedVector2Array([c, c - d * h + n * h * 0.62, c - d * h - n * h * 0.62])
	var b := PackedVector2Array([c, c + d * h + n * h * 0.62, c + d * h - n * h * 0.62])
	ci.draw_colored_polygon(a, col)
	ci.draw_colored_polygon(b, col if kind != "check" else col.darkened(0.45))
	for tri in [a, b]:
		var loop := PackedVector2Array(tri)
		loop.append(tri[0])
		ci.draw_polyline(loop, STEEL_DARK, 1.5, true)
	match kind:
		"relief":
			# A spring on top.
			var p := c
			for k in 4:
				var q := c + n * h * (0.35 + 0.3 * float(k + 1)) + d * h * (0.3 if k % 2 == 0 else -0.3)
				ci.draw_line(p, q, STEEL_LIGHT, 1.5, true)
				p = q
		"check":
			ci.draw_line(c - n * h * 0.62, c + n * h * 0.62, STEEL_LIGHT, 2.0, true)
		_:
			ci.draw_line(c, c + n * h * 1.25, STEEL_LIGHT, 2.0, true)
			var top := c + n * h * 1.25
			if open:
				# Handle along the pipe: open.
				ci.draw_line(top - d * h * 0.75, top + d * h * 0.75, col, 3.0, true)
			else:
				# Handle seen end on: shut.
				ci.draw_line(top - d * h * 0.25, top + d * h * 0.25, col, 3.0, true)
				GraphFastDraw.disc(ci, top, h * 0.22, col)


## A heating element from `a` (where it enters) to `b` (its tip).
static func heater(ci: CanvasItem, a: Vector2, b: Vector2, w: float, on: bool, t_c: float, fused: bool, sel: bool, hover: bool) -> void:
	var col := STEEL_DARK.lightened(0.2)
	if fused:
		col = WARN
	elif on:
		col = heat_rgb(maxf(t_c, 300.0)).lerp(HOT, 0.5)
	if sel or hover:
		ci.draw_line(a, b, Color(SELECT, 0.9 if sel else 0.45), w + 6.0, true)
	if on and not fused:
		ci.draw_line(a, b, Color(HOT, 0.25), w * 2.6, true)
	ci.draw_line(a, b, STEEL_DARK, w + 2.0, true)
	ci.draw_line(a, b, col, w, true)
	# The head outside the vessel.
	var d := (a - b).normalized() if a.distance_to(b) > 0.1 else Vector2.DOWN
	GraphFastDraw.rrect(ci, Rect2(a + d * w * 1.2 - Vector2(w, w) * 1.1, Vector2(w, w) * 2.2), 3.0, STEEL)
	GraphFastDraw.rrect_border(ci, Rect2(a + d * w * 1.2 - Vector2(w, w) * 1.1, Vector2(w, w) * 2.2), 3.0, STEEL_DARK, 1)


## An instrument bubble (the P&ID circle with letters) at `c`.
static func instrument(ci: CanvasItem, c: Vector2, r: float, letters: String, font: Font, sel: bool, hover: bool) -> void:
	if sel or hover:
		GraphFastDraw.ring(ci, c, r + 4.0, Color(SELECT, 0.9 if sel else 0.45), 3.0)
	GraphFastDraw.disc(ci, c, r, Color(0.09, 0.12, 0.18))
	GraphFastDraw.ring(ci, c, r, STEEL_LIGHT, 1.5)
	if r >= 8.0 and font != null:
		var fs := int(clampf(r * 0.85, 8.0, 16.0))
		var sz := font.get_string_size(letters, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
		ci.draw_string(font, c + Vector2(-sz.x * 0.5, fs * 0.36), letters, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, TEXT)


## An open end: an arrow along `dir` (out of the pipe). `role`: feed |
## product | drain | coolant_in | coolant_out | outlet | atmosphere | plug.
static func end(ci: CanvasItem, c: Vector2, s: float, dir: Vector2, role: String, open: bool, flowing: bool, sel: bool, hover: bool) -> void:
	var d := dir.normalized() if dir.length() > 0.01 else Vector2.UP
	var n := Vector2(-d.y, d.x)
	if sel or hover:
		GraphFastDraw.ring(ci, c, s * 0.8, Color(SELECT, 0.9 if sel else 0.45), 3.0)
	if role == "plug":
		# A capped bung: a short stub with a cap across it.
		var base := c - d * s * 0.6
		ci.draw_line(base, base + d * s * 0.22, STEEL, maxf(s * 0.22, 2.0), true)
		ci.draw_line(base + d * s * 0.22 - n * s * 0.2, base + d * s * 0.22 + n * s * 0.2, STEEL_LIGHT, 2.0, true)
		return
	var col := CLOSED
	if open:
		col = OPEN if flowing else Color(OPEN, 0.55)
	if role == "coolant_in" or role == "coolant_out":
		col = COOLANT.lightened(0.3)
	var into := role == "feed" or role == "coolant_in"
	var tip := c + d * s * (-0.3 if into else 0.5)
	var back := c + d * s * (0.5 if into else -0.3)
	ci.draw_line(back, tip, col, 3.0, true)
	var hd := (tip - back).normalized()
	var hn := Vector2(-hd.y, hd.x)
	ci.draw_colored_polygon(PackedVector2Array([tip + hd * s * 0.22, tip - hd * s * 0.2 + hn * s * 0.24, tip - hd * s * 0.2 - hn * s * 0.24]), col)
	if not open:
		ci.draw_line(c - n * s * 0.35 - d * s * 0.3, c + n * s * 0.35 - d * s * 0.3, CLOSED, 3.0, true)


## A value tag: dark pill with text, anchored by its top-left. Returns its rect.
static func tag(ci: CanvasItem, pos: Vector2, text: String, font: Font, fs: int, col: Color = TEXT, accent: Color = Color(0, 0, 0, 0)) -> Rect2:
	if font == null or text.is_empty():
		return Rect2(pos, Vector2.ZERO)
	var sz := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	var r := Rect2(pos, Vector2(sz.x + 12.0, fs + 8.0))
	GraphFastDraw.rrect(ci, r, 4.0, TAG_BG)
	ci.draw_rect(r, Color(STEEL, 0.45), false, 1.0)
	if accent.a > 0.0:
		ci.draw_rect(Rect2(r.position.x, r.position.y + 2.0, 3.0, r.size.y - 4.0), accent)
	ci.draw_string(font, r.position + Vector2(6.0, fs + 2.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
	return r


# ── single-line and network symbols (Phase 3b) ─────────────────────────────

## A power or data run: a thin line. opts {color, selected, hover, flow,
## phase, dashed, warn}.
static func wire(ci: CanvasItem, pts: PackedVector2Array, w: float, o: Dictionary) -> void:
	if pts.size() < 2:
		return
	var col: Color = o.get("color", STEEL_LIGHT)
	if bool(o.get("warn", false)):
		col = WARN
	if bool(o.get("selected", false)) or bool(o.get("hover", false)):
		ci.draw_polyline(pts, Color(SELECT, 0.55 if bool(o.get("selected", false)) else 0.3), w + 6.0, true)
	if bool(o.get("dashed", false)):
		var total := MimicLayout.length_of(pts)
		var d := 0.0
		while d < total:
			var a: Vector2 = MimicLayout.point_at(pts, d)[0]
			var b: Vector2 = MimicLayout.point_at(pts, minf(d + 9.0, total))[0]
			ci.draw_line(a, b, col, w, true)
			d += 17.0
	else:
		ci.draw_polyline(pts, col.darkened(0.45), w + 2.0, true)
		ci.draw_polyline(pts, col, maxf(w - 1.0, 1.5), true)
	if int(o.get("flow", 0)) != 0:
		var total2 := MimicLayout.length_of(pts)
		var step := 26.0
		var d2 := fposmod(float(o.get("phase", 0.0)) * 34.0, step)
		while d2 < total2:
			ci.draw_circle(MimicLayout.point_at(pts, d2)[0], maxf(w * 0.42, 1.6), col.lightened(0.6))
			d2 += step


## A device box with its single-line glyph. opts {glyph, selected, hover, on,
## warn}.
static func device(ci: CanvasItem, r: Rect2, o: Dictionary) -> void:
	var warn := bool(o.get("warn", false))
	var on := bool(o.get("on", true))
	ci.draw_rect(r, Color(0.105, 0.125, 0.165))
	ci.draw_rect(Rect2(r.position, Vector2(r.size.x, maxf(r.size.y * 0.06, 2.0))), WARN if warn else (OPEN if on else STEEL))
	ci.draw_rect(r, SELECT if bool(o.get("selected", false)) else (STEEL_LIGHT if bool(o.get("hover", false)) else STEEL_DARK), false, 2.0 if bool(o.get("selected", false)) else 1.5)
	# The reading stands across the top of the box; the glyph sits under it.
	var c := r.get_center() + Vector2(0, r.size.y * 0.17)
	var u := minf(r.size.x, r.size.y) * 0.21
	var ink := STEEL_LIGHT if on else STEEL
	var pg: Variant = o.get("pictogram", null)
	if str(o.get("glyph", "box")) == "box" and pg is Texture2D:
		_pictogram(ci, r, pg as Texture2D, ink)
		return
	var lw := maxf(u * 0.11, 1.5)
	match str(o.get("glyph", "box")):
		"battery":
			for k in 2:
				var x := c.x + (float(k) - 0.5) * u * 0.9
				ci.draw_line(Vector2(x - u * 0.2, c.y - u * 0.75), Vector2(x - u * 0.2, c.y + u * 0.75), ink, lw)
				ci.draw_line(Vector2(x + u * 0.2, c.y - u * 0.4), Vector2(x + u * 0.2, c.y + u * 0.4), ink, lw * 2.0)
		"panel":
			var pr := Rect2(c - Vector2(u, u * 0.7), Vector2(u * 2.0, u * 1.4))
			ci.draw_rect(pr, ink, false, lw)
			ci.draw_line(Vector2(c.x, pr.position.y), Vector2(c.x, pr.end.y), ink, lw * 0.7)
			ci.draw_line(Vector2(pr.position.x, c.y), Vector2(pr.end.x, c.y), ink, lw * 0.7)
		"inverter":
			var ir := Rect2(c - Vector2(u, u * 0.75), Vector2(u * 2.0, u * 1.5))
			ci.draw_rect(ir, ink, false, lw)
			ci.draw_line(ir.position + Vector2(0, ir.size.y), ir.position + Vector2(ir.size.x, 0), ink, lw * 0.7)
			ci.draw_line(ir.position + Vector2(u * 0.25, u * 0.4), ir.position + Vector2(u * 0.8, u * 0.4), ink, lw)
			ci.draw_arc(ir.end - Vector2(u * 0.7, u * 0.4), u * 0.2, PI, TAU, 8, ink, lw)
			ci.draw_arc(ir.end - Vector2(u * 0.3, u * 0.4), u * 0.2, 0.0, PI, 8, ink, lw)
		"load":
			ci.draw_arc(c, u * 0.8, 0.0, TAU, 24, ink, lw, true)
			ci.draw_line(c + Vector2(-u, -u) * 0.56, c + Vector2(u, u) * 0.56, ink, lw)
			ci.draw_line(c + Vector2(-u, u) * 0.56, c + Vector2(u, -u) * 0.56, ink, lw)
		"generator":
			ci.draw_arc(c, u * 0.8, 0.0, TAU, 24, ink, lw, true)
			ci.draw_arc(c - Vector2(u * 0.22, 0), u * 0.22, PI, TAU, 8, ink, lw)
			ci.draw_arc(c + Vector2(u * 0.22, 0), u * 0.22, 0.0, PI, 8, ink, lw)
		"breaker":
			ci.draw_line(c - Vector2(u, 0), c - Vector2(u * 0.4, 0), ink, lw)
			ci.draw_line(c + Vector2(u * 0.4, 0), c + Vector2(u, 0), ink, lw)
			ci.draw_line(c - Vector2(u * 0.4, 0), c + Vector2(u * 0.3, -u * 0.55), ink, lw)
			ci.draw_circle(c - Vector2(u * 0.4, 0), lw * 1.1, ink)
			ci.draw_circle(c + Vector2(u * 0.4, 0), lw * 1.1, ink)
		"server":
			for k in 3:
				var sr := Rect2(c.x - u, c.y - u * 0.85 + float(k) * u * 0.6, u * 2.0, u * 0.46)
				ci.draw_rect(sr, ink, false, lw)
				ci.draw_circle(sr.position + Vector2(u * 0.25, u * 0.23), lw, OPEN if on else STEEL)
		"switch":
			var wr := Rect2(c - Vector2(u * 1.2, u * 0.45), Vector2(u * 2.4, u * 0.9))
			ci.draw_rect(wr, ink, false, lw)
			for k in 5:
				ci.draw_rect(Rect2(wr.position.x + u * 0.2 + float(k) * u * 0.42, c.y - u * 0.14, u * 0.26, u * 0.28), ink)
		"ap":
			ci.draw_circle(c + Vector2(0, u * 0.6), lw * 1.6, ink)
			for k in 3:
				ci.draw_arc(c + Vector2(0, u * 0.6), u * (0.45 + 0.4 * float(k)), -PI * 0.78, -PI * 0.22, 12, ink, lw, true)
		"board":
			var br := Rect2(c - Vector2(u * 0.7, u * 0.7), Vector2(u * 1.4, u * 1.4))
			ci.draw_rect(br, ink, false, lw)
			for k in 4:
				var t := (float(k) + 0.5) / 4.0
				ci.draw_line(Vector2(br.position.x - u * 0.3, br.position.y + br.size.y * t), Vector2(br.position.x, br.position.y + br.size.y * t), ink, lw * 0.8)
				ci.draw_line(Vector2(br.end.x, br.position.y + br.size.y * t), Vector2(br.end.x + u * 0.3, br.position.y + br.size.y * t), ink, lw * 0.8)
		_:
			ci.draw_rect(Rect2(c - Vector2(u, u * 0.6), Vector2(u * 2.0, u * 1.2)), ink, false, lw)


# ── dashboard widgets (SCADA plan, Phase 8) ─────────────────────────────────

const WIDGET_BG := Color(0.06, 0.08, 0.125, 0.95)
const WIDGET_TRACK := Color(0.15, 0.18, 0.25)
const WIDGET_ON := Color(0.11, 0.34, 0.21)
const WIDGET_OFF := Color(0.13, 0.16, 0.23)


## Where along a slider's track a screen x falls (0..1). The drawing and the
## click use the same numbers.
static func slider_frac(r: Rect2, x: float) -> float:
	var s := r.size.y / 56.0
	var x0 := r.position.x + 10.0 * s + r.size.y * 0.16
	var x1 := r.end.x - 10.0 * s - r.size.y * 0.16
	return clampf((x - x0) / maxf(x1 - x0, 1.0), 0.0, 1.0)


static func _wtext(ci: CanvasItem, font: Font, pos: Vector2, text: String, fs: int, col: Color, width: float = -1.0, align: int = HORIZONTAL_ALIGNMENT_LEFT) -> void:
	if font == null or fs < 7 or text.is_empty():
		return
	ci.draw_string(font, pos, text, align, width, fs, col)


## One widget in its screen rect. `st` = MimicWidgets.state(...).
static func widget(ci: CanvasItem, r: Rect2, wkind: String, st: Dictionary, font: Font, sel: bool, hover: bool) -> void:
	if r.size.x < 8.0 or r.size.y < 8.0:
		return
	var base: Vector2 = MimicWidgets.SIZES.get(wkind, Vector2(150, 56))
	var s := r.size.y / base.y
	var fs := int(clampf(11.0 * s, 5.0, 24.0))
	var big := int(clampf(21.0 * s, 7.0, 46.0))
	var pad := 8.0 * s
	var rad := int(clampf(6.0 * s, 2.0, 10.0))
	var avail := bool(st.get("avail", false))
	var bound := bool(st.get("bound", false)) or wkind in ["text", "nav"]
	var accent: Color = LIQUID if avail else WARN
	var label := str(st.get("label", ""))
	var text := str(st.get("text", ""))
	var frac := float(st.get("frac", 0.0))
	if wkind != "text":
		GraphFastDraw.rrect(ci, r, rad, WIDGET_BG)
		GraphFastDraw.rrect_border(ci, r, rad, Color(STEEL, 0.7), 1)
	if not bound:
		_wtext(ci, font, Vector2(r.position.x + pad, r.get_center().y + fs * 0.36), text, fs, WARN, r.size.x - pad * 2.0)
		if sel or hover:
			GraphFastDraw.rrect_border(ci, r.grow(2.0), rad, Color(SELECT, 0.95 if sel else 0.5), 2)
		return
	var tw := r.size.x - pad * 2.0
	match wkind:
		"gauge":
			_wtext(ci, font, Vector2(r.position.x + pad, r.position.y + pad + fs * 0.8), label, fs, TEXT_DIM, tw, HORIZONTAL_ALIGNMENT_CENTER)
			var c := Vector2(r.get_center().x, r.position.y + r.size.y * 0.66)
			var gr := minf(r.size.x * 0.36, r.size.y * 0.40)
			var a0 := deg_to_rad(150.0)
			var a1 := deg_to_rad(390.0)
			var th := maxf(gr * 0.17, 2.0)
			ci.draw_arc(c, gr, a0, a1, 36, WIDGET_TRACK, th, true)
			if avail and frac > 0.002:
				ci.draw_arc(c, gr, a0, lerpf(a0, a1, frac), maxi(int(36.0 * frac), 3), accent, th, true)
			if avail:
				var an := lerpf(a0, a1, frac)
				ci.draw_line(c, c + Vector2(cos(an), sin(an)) * gr * 0.84, TEXT, maxf(1.5, 2.0 * s), true)
			GraphFastDraw.disc(ci, c, maxf(gr * 0.09, 2.0), STEEL_LIGHT)
			_wtext(ci, font, Vector2(r.position.x + pad, c.y + gr * 0.62), text, int(clampf(15.0 * s, 6.0, 34.0)), TEXT if avail else WARN, tw, HORIZONTAL_ALIGNMENT_CENTER)
			if fs >= 9:
				var sf := maxi(fs - 2, 7)
				_wtext(ci, font, c + Vector2(cos(a0), sin(a0)) * gr + Vector2(-gr * 0.2, sf + 3.0), MimicWidgets.fmt(float(st.get("lo", 0.0))), sf, TEXT_DIM)
				_wtext(ci, font, c + Vector2(cos(a1), sin(a1)) * gr + Vector2(-gr * 0.1, sf + 3.0), MimicWidgets.fmt(float(st.get("hi", 100.0))), sf, TEXT_DIM)
		"bar":
			_wtext(ci, font, Vector2(r.position.x + 3.0, r.position.y + pad + fs * 0.8), label, fs, TEXT_DIM, r.size.x - 6.0, HORIZONTAL_ALIGNMENT_CENTER)
			var top := r.position.y + pad + fs + 6.0 * s
			var bot := r.end.y - pad - fs - 6.0 * s
			var bw := r.size.x * 0.38
			var tr := Rect2(r.get_center().x - bw * 0.5, top, bw, maxf(bot - top, 2.0))
			ci.draw_rect(tr, WIDGET_TRACK)
			if avail:
				var fh := tr.size.y * frac
				ci.draw_rect(Rect2(tr.position.x, tr.end.y - fh, tr.size.x, fh), accent)
			ci.draw_rect(tr, Color(STEEL_LIGHT, 0.6), false, 1.0)
			_wtext(ci, font, Vector2(r.position.x + 3.0, r.end.y - pad * 0.7), text, fs, TEXT if avail else WARN, r.size.x - 6.0, HORIZONTAL_ALIGNMENT_CENTER)
		"value":
			_wtext(ci, font, Vector2(r.position.x + pad, r.position.y + pad + fs * 0.8), label, fs, TEXT_DIM, tw)
			_wtext(ci, font, Vector2(r.position.x + pad, r.end.y - pad), text, big, TEXT if avail else WARN, tw)
		"trend":
			_wtext(ci, font, Vector2(r.position.x + pad, r.position.y + pad + fs * 0.8), label, fs, TEXT_DIM, tw * 0.6)
			_wtext(ci, font, Vector2(r.position.x + pad, r.position.y + pad + fs * 0.8), text, fs, TEXT if avail else WARN, tw, HORIZONTAL_ALIGNMENT_RIGHT)
			var pr := Rect2(r.position.x + pad, r.position.y + pad + fs + 5.0 * s, tw, r.size.y - pad * 2.0 - fs - 5.0 * s)
			if pr.size.y > 4.0:
				ci.draw_rect(pr, Color(WIDGET_TRACK, 0.55))
				var data: PackedFloat32Array = st.get("trend", PackedFloat32Array())
				var lo := float(st.get("lo", 0.0))
				var hi := float(st.get("hi", 100.0))
				var n := data.size()
				if n >= 2:
					var run := PackedVector2Array()
					for i in n:
						var v := data[i]
						if is_nan(v):
							if run.size() >= 2:
								ci.draw_polyline(run, accent, maxf(1.5, 1.6 * s), true)
							run = PackedVector2Array()
							continue
						run.append(Vector2(pr.position.x + pr.size.x * float(i) / float(n - 1),
							pr.end.y - pr.size.y * clampf((v - lo) / maxf(hi - lo, 1e-9), 0.0, 1.0)))
					if run.size() >= 2:
						ci.draw_polyline(run, accent, maxf(1.5, 1.6 * s), true)
		"lamp":
			var lr := r.size.y * 0.27
			var lc := Vector2(r.position.x + pad + lr, r.get_center().y)
			var on := bool(st.get("on", false)) and avail
			if on:
				GraphFastDraw.disc(ci, lc, lr * 1.45, Color(OPEN, 0.22))
			GraphFastDraw.disc(ci, lc, lr, OPEN if on else Color(0.19, 0.22, 0.29))
			GraphFastDraw.ring(ci, lc, lr, STEEL_LIGHT if avail else WARN, 1.5)
			_wtext(ci, font, Vector2(lc.x + lr + pad, r.get_center().y + fs * 0.36), label, fs, TEXT if avail else WARN, r.end.x - (lc.x + lr + pad) - pad * 0.5)
		"button", "nav":
			var on2 := bool(st.get("on", false)) and avail and wkind == "button"
			var ir := r.grow(-3.0 * s)
			GraphFastDraw.rrect(ci, ir, rad, WIDGET_ON if on2 else WIDGET_OFF)
			GraphFastDraw.rrect_border(ci, ir, rad, OPEN if on2 else (STEEL_LIGHT if avail else WARN), 2 if on2 else 1)
			if wkind == "button":
				_wtext(ci, font, Vector2(ir.position.x + pad * 0.5, ir.position.y + ir.size.y * 0.46), label, fs, TEXT, ir.size.x - pad, HORIZONTAL_ALIGNMENT_CENTER)
				var stt := text if bool(st.get("writable", false)) else "cannot be switched"
				_wtext(ci, font, Vector2(ir.position.x + pad * 0.5, ir.position.y + ir.size.y * 0.46 + fs + 2.0), stt, maxi(fs - 1, 7), OPEN if on2 else (TEXT_DIM if bool(st.get("writable", false)) else WARN), ir.size.x - pad, HORIZONTAL_ALIGNMENT_CENTER)
			else:
				_wtext(ci, font, Vector2(ir.position.x + pad, ir.get_center().y + fs * 0.4), text, int(fs * 1.1), TEXT if avail else WARN, ir.size.x - pad * 3.2)
				var ax := ir.end.x - pad * 1.3
				var ay := ir.get_center().y
				var ah := ir.size.y * 0.16
				ci.draw_polyline(PackedVector2Array([Vector2(ax - ah, ay - ah), Vector2(ax, ay), Vector2(ax - ah, ay + ah)]), STEEL_LIGHT, maxf(1.5, 2.0 * s), true)
		"slider":
			_wtext(ci, font, Vector2(r.position.x + pad, r.position.y + pad + fs * 0.8), label, fs, TEXT_DIM, tw * 0.62)
			_wtext(ci, font, Vector2(r.position.x + pad, r.position.y + pad + fs * 0.8), text, fs, TEXT if avail else WARN, tw, HORIZONTAL_ALIGNMENT_RIGHT)
			var kr := r.size.y * 0.16
			var x0 := r.position.x + 10.0 * s + kr
			var x1 := r.end.x - 10.0 * s - kr
			var y := r.position.y + r.size.y * 0.70
			ci.draw_line(Vector2(x0, y), Vector2(x1, y), WIDGET_TRACK, maxf(4.0 * s, 2.0), true)
			if avail:
				var kx := lerpf(x0, x1, frac)
				ci.draw_line(Vector2(x0, y), Vector2(kx, y), accent, maxf(4.0 * s, 2.0), true)
				GraphFastDraw.disc(ci, Vector2(kx, y), kr, TEXT if bool(st.get("writable", false)) else CLOSED)
				GraphFastDraw.ring(ci, Vector2(kx, y), kr, STEEL_DARK, 1.5)
		"text":
			_wtext(ci, font, Vector2(r.position.x + pad * 0.5, r.get_center().y + big * 0.36), text, int(clampf(17.0 * s, 7.0, 40.0)), TEXT, r.size.x - pad)
	if sel or hover:
		GraphFastDraw.rrect_border(ci, r.grow(2.0), rad, Color(SELECT, 0.95 if sel else 0.5), 2)
