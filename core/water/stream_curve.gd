class_name StreamCurve
extends RefCounted

## The path a stream actually runs along, from its waypoints — pure.
##
## Waypoints (OSM vertices, or the player's pins) are CONTROL points. Mapped
## waterways are digitised as a handful of straight runs; a real channel
## bends. Two knobs turn the control polyline into the channel's centreline:
##
##   smooth   0..1  rounds every corner: a centripetal Catmull-Rom spline
##                  through the waypoints (Yuksel, Schaefer & Keyser 2011 —
##                  the centripetal form never cusps or loops between points),
##                  blended with the straight polyline by `smooth`. The line
##                  still passes through every waypoint, so pins stay on it.
##   meander  0..1  bends the smoothed line into meanders: a sine-generated
##                  curve (Langbein & Leopold 1966) — the heading swings
##                  θ = ω·cos φ about the valley line as the channel walks its
##                  own length, φ advancing one turn per meander — with the
##                  Kinoshita (1961) third harmonic for the skewed, upstream-
##                  leaning bends real rivers have. ω = meander × OMEGA_MAX:
##                  0.5 reads as a lazy wander, 1.0 as tight goosenecks whose
##                  necks nearly touch — the loops that cut off into oxbows.
##
## Wavelength follows the channel: meanders measured along the valley run
## ~11 bankfull widths per wave (Leopold & Wolman 1960; Williams 1986), so a
## ditch wiggles tightly and a river swings wide. Each wave draws its own
## length and swing from the stream's seed (±25 %, ±15 %) so no two bends
## repeat. Lateral offset is pinned to zero at both ends, at `pins` (where
## tributaries join, so they still meet the channel), and across `flat` arc
## ranges (culverts and pipes run straight under the road they cross).
##
## Returns {points, seg, vtx}:
##   points  PackedVector2Array, the centreline (~`step` m apart), downstream
##   seg     PackedInt32Array, per span of `points`: the control span it is in
##   vtx     PackedInt32Array, per control vertex: the index in `points`
## smooth == meander == 0 returns the control line itself (identity — a world
## with the sliders at zero carves byte-identically to before they existed).

## Heading swing at meander 1.0 (rad, ≈115°). Langbein & Leopold put strongly
## meandering rivers at ~110°; past ~126° a sine-generated curve crosses itself.
const OMEGA_MAX := 2.0
## No single wave swings past this (rad): a sine-generated curve with ω above
## ~2.2 rad (126°) loops across itself, which a channel cannot do.
const OMEGA_CROSS := 2.1
## Valley-measured meander wavelength in bankfull widths.
const WAVE_WIDTHS := 11.0
## Kinoshita skewness / flatness coefficients (multiply ω³). Small: a hint of
## lean, not a different shape (Parker, Diplas & Akiyama 1983 fit 0.01–0.03).
const KINOSHITA_SKEW := 0.020
const KINOSHITA_FLAT := 0.006
## How far (in wavelengths) the meander takes to grow from a pinned point.
const PIN_RAMP_WAVES := 0.6
const DEFAULT_STEP_M := 2.0


static func is_identity(smooth: float, meander: float) -> bool:
	return smooth <= 0.001 and meander <= 0.001


## Bessel J0(x) = (1/π)∫₀^π cos(x sin t) dt — the valley progress per unit
## path length of a sine-generated curve (Langbein & Leopold 1966).
static func bessel_j0(x: float) -> float:
	var n := 48
	var acc := 0.0
	for i in n:
		var t := (float(i) + 0.5) / float(n) * PI
		acc += cos(x * sin(t))
	return acc / float(n)


## Valley wavelength (m) for a channel of bankfull top width `width_m`.
static func wavelength_for_width(width_m: float) -> float:
	return maxf(WAVE_WIDTHS * maxf(width_m, 0.5), 8.0)


static func curve(ctrl: PackedVector2Array, smooth: float, meander: float,
		wavelength_m: float, seed: int, pins: PackedVector2Array = PackedVector2Array(),
		flat: Array = [], step: float = DEFAULT_STEP_M) -> Dictionary:
	var n := ctrl.size()
	if n < 2 or is_identity(smooth, meander):
		return _identity(ctrl)
	var base := _smoothed(ctrl, clampf(smooth, 0.0, 1.0), step)
	if meander <= 0.001:
		return base
	return _meandered(ctrl, base, clampf(meander, 0.0, 1.0), wavelength_m, seed, pins, flat, step)


static func _identity(ctrl: PackedVector2Array) -> Dictionary:
	var seg := PackedInt32Array()
	var vtx := PackedInt32Array()
	for i in ctrl.size():
		vtx.append(i)
		if i < ctrl.size() - 1:
			seg.append(i)
	return {"points": ctrl.duplicate(), "seg": seg, "vtx": vtx}


## Corner rounding: each control span sampled along the centripetal
## Catmull-Rom segment through its neighbours, mixed with the straight span.
static func _smoothed(ctrl: PackedVector2Array, smooth: float, step: float) -> Dictionary:
	var n := ctrl.size()
	var pts := PackedVector2Array()
	var seg := PackedInt32Array()
	var vtx := PackedInt32Array()
	pts.append(ctrl[0])
	vtx.append(0)
	for i in n - 1:
		var p1 := ctrl[i]
		var p2 := ctrl[i + 1]
		# Phantom end points mirror the first / last span (the curve leaves
		# and arrives along it).
		var p0 := ctrl[i - 1] if i > 0 else p1 - (p2 - p1)
		var p3 := ctrl[i + 2] if i + 2 < n else p2 + (p2 - p1)
		var length := p1.distance_to(p2)
		var k := maxi(int(ceil(length / maxf(step, 0.25))), 1)
		for j in range(1, k + 1):
			var t := float(j) / float(k)
			var q := p2 if j == k else p1.lerp(p2, t)
			if smooth > 0.0 and j < k:
				q = q.lerp(_catmull_rom(p0, p1, p2, p3, t), smooth)
			pts.append(q)
			seg.append(i)
		vtx.append(pts.size() - 1)
	return {"points": pts, "seg": seg, "vtx": vtx}


## Centripetal (α = 0.5) Catmull-Rom between p1 and p2, Barry–Goldman form.
static func _catmull_rom(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, t: float) -> Vector2:
	var t0 := 0.0
	var t1 := t0 + maxf(sqrt(p0.distance_to(p1)), 1e-4)
	var t2 := t1 + maxf(sqrt(p1.distance_to(p2)), 1e-4)
	var t3 := t2 + maxf(sqrt(p2.distance_to(p3)), 1e-4)
	var tt := lerpf(t1, t2, t)
	var a1 := p0 * ((t1 - tt) / (t1 - t0)) + p1 * ((tt - t0) / (t1 - t0))
	var a2 := p1 * ((t2 - tt) / (t2 - t1)) + p2 * ((tt - t1) / (t2 - t1))
	var a3 := p2 * ((t3 - tt) / (t3 - t2)) + p3 * ((tt - t2) / (t3 - t2))
	var b1 := a1 * ((t2 - tt) / (t2 - t0)) + a2 * ((tt - t0) / (t2 - t0))
	var b2 := a2 * ((t3 - tt) / (t3 - t1)) + a3 * ((tt - t1) / (t3 - t1))
	return b1 * ((t2 - tt) / (t2 - t1)) + b2 * ((tt - t1) / (t2 - t1))


## Deterministic 0..1 for (seed, i, salt).
static func _u(seed: int, i: int, salt: int) -> float:
	var h := hash([seed, i, salt])
	return float(h & 0xFFFFFF) / float(0xFFFFFF)


static func _meandered(ctrl: PackedVector2Array, base: Dictionary, meander: float,
		wavelength_m: float, seed: int, pins: PackedVector2Array, flat: Array,
		step: float) -> Dictionary:
	var bp: PackedVector2Array = base["points"]
	var bseg: PackedInt32Array = base["seg"]
	var bvtx: PackedInt32Array = base["vtx"]
	var nb := bp.size()
	# Arc length of the smoothed (valley) line.
	var bs := PackedFloat32Array()
	bs.resize(nb)
	for i in range(1, nb):
		bs[i] = bs[i - 1] + bp[i - 1].distance_to(bp[i])
	var total := bs[nb - 1]
	var lam := maxf(wavelength_m, 4.0 * step)
	if total < lam * 0.75:
		return base
	# Envelope over valley arc: 0 at the ends, at pins and across flat spans,
	# growing back over PIN_RAMP_WAVES wavelengths.
	var ramp := lam * PIN_RAMP_WAVES
	var pin_s := PackedFloat32Array([0.0, total])
	for p in pins:
		var hit := StreamNetwork.nearest_on_line(bp, p)
		pin_s.append(float(hit["s"]))
	var flat_s: Array = []
	for r in flat:
		var a: int = int((r as Vector2i).x)
		var b: int = int((r as Vector2i).y)
		if a >= 0 and b < bvtx.size() and b > a:
			flat_s.append(Vector2(bs[bvtx[a]], bs[bvtx[b]]))
	var env_fn := func(x: float) -> float:
		var d := INF
		for ps in pin_s:
			d = minf(d, absf(x - float(ps)))
		for fr in flat_s:
			var v: Vector2 = fr
			if x >= v.x and x <= v.y:
				return 0.0
			d = minf(d, minf(absf(x - v.x), absf(x - v.y)))
		return smoothstep(0.0, ramp, d)

	# Walk the channel's own length σ; each wave keeps one ω and length so it
	# closes back on the valley line (y = 0 at wave ends) whatever its shape.
	var omega := meander * OMEGA_MAX
	var j0 := maxf(bessel_j0(omega), 0.12)
	var path_wave := lam / j0
	var flip := -1.0 if _u(seed, 0, 7) < 0.5 else 1.0
	var xs := PackedFloat32Array([0.0])
	var ys := PackedFloat32Array([0.0])
	var wave_start := PackedInt32Array([0])
	var x := 0.0
	var y := 0.0
	var k := 0
	var guard := int(total / step) * 12 + 1000
	while x < total and xs.size() < guard:
		var mk := path_wave * (0.75 + 0.5 * _u(seed, k, 1))
		var env_mid := float(env_fn.call(x + 0.5 * lam))
		var wk := minf(omega * (0.85 + 0.3 * _u(seed, k, 2)), OMEGA_CROSS) * minf(env_mid * 1.25, 1.0)
		var w3 := wk * wk * wk
		var steps := maxi(int(ceil(mk / step)), 8)
		var ds := mk / float(steps)
		for j in steps:
			var phi := TAU * (float(j) + 0.5) / float(steps)
			var th := wk * cos(phi) + w3 * (KINOSHITA_SKEW * cos(3.0 * phi) - KINOSHITA_FLAT * sin(3.0 * phi))
			x += cos(th) * ds
			y += flip * sin(th) * ds
			xs.append(x)
			ys.append(y)
		wave_start.append(xs.size() - 1)
		k += 1
	# Close every wave exactly (the skew harmonic leaves a small residual).
	for w in range(wave_start.size() - 1):
		var a := wave_start[w]
		var b := wave_start[w + 1]
		var ya := ys[a]
		var yb := ys[b]
		for i in range(a, b + 1):
			var f := float(i - a) / float(maxi(b - a, 1))
			ys[i] -= lerpf(ya, yb, f)
	# Map (x along the valley, y across it) onto the smoothed line, fading the
	# swing by the envelope. The last wave overshoots the end: stop there.
	var pts := PackedVector2Array()
	var seg := PackedInt32Array()
	var bi := 0
	for i in xs.size():
		var xv := clampf(xs[i], 0.0, total)
		while bi < nb - 2 and bs[bi + 1] < xv:
			bi += 1
		while bi > 0 and bs[bi] > xv:
			bi -= 1
		var sl := maxf(bs[bi + 1] - bs[bi], 1e-6)
		var t := clampf((xv - bs[bi]) / sl, 0.0, 1.0)
		var c := bp[bi].lerp(bp[bi + 1], t)
		var tg := _tangent(bp, bi, t)
		var nrm := Vector2(-tg.y, tg.x)
		var q := c + nrm * (ys[i] * float(env_fn.call(xv)))
		if pts.is_empty() or q.distance_squared_to(pts[pts.size() - 1]) > 0.04:
			if not pts.is_empty():
				seg.append(bseg[mini(bi, bseg.size() - 1)])
			pts.append(q)
		if xs[i] >= total:
			break
	# End exactly on the last control point.
	var last := bp[nb - 1]
	if pts[pts.size() - 1].distance_squared_to(last) > 1e-6:
		seg.append(bseg[bseg.size() - 1])
		pts.append(last)
	pts[0] = bp[0]
	# Control vertex → nearest centreline index at the same valley position.
	var vtx := PackedInt32Array()
	var cursor := 0
	for vi in ctrl.size():
		var target := ctrl[vi]
		var best := cursor
		var best_d := INF
		for i in range(cursor, pts.size()):
			var d := pts[i].distance_squared_to(target)
			if d < best_d:
				best_d = d
				best = i
		if vi == ctrl.size() - 1:
			best = pts.size() - 1
		vtx.append(best)
		cursor = best
	return {"points": pts, "seg": seg, "vtx": vtx}


## Unit tangent of the valley line at span `i`, parameter `t` — blended with
## the neighbouring spans' tangents so the normal turns smoothly at vertices
## (a hard switch would tear the offset curve apart on the outside of a bend).
static func _tangent(bp: PackedVector2Array, i: int, t: float) -> Vector2:
	var here := (bp[i + 1] - bp[i]).normalized()
	var prev := (bp[i] - bp[i - 1]).normalized() if i > 0 else here
	var next := (bp[i + 2] - bp[i + 1]).normalized() if i + 2 < bp.size() else here
	var a := (prev + here).normalized() if (prev + here).length_squared() > 1e-8 else here
	var b := (here + next).normalized() if (here + next).length_squared() > 1e-8 else here
	var out := a.lerp(b, t)
	return out.normalized() if out.length_squared() > 1e-8 else here
