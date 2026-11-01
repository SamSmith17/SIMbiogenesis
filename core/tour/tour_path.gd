class_name TourPath
extends RefCounted

## The tour camera's paths (pure). A fly is a centripetal Catmull–Rom spline
## through the stop's waypoints (Barry & Goldman's form; centripetal never
## loops or overshoots on unevenly spaced points, Yuksel et al. 2011), walked
## at constant speed by arc length with a trapezoid speed profile: it eases
## in, cruises, eases out. The look-at points ride their own spline on the
## same parameter.
##
## What it replaced: straight lines between the waypoints under ONE smoothstep
## over the whole path, so the camera's speed jumped at every waypoint and the
## look point slid in straight lines, which wobbled the view.

const SAMPLES_PER_SEGMENT := 24


## Centripetal Catmull–Rom between p1 and p2 (t in 0..1); p0 / p3 are the
## neighbours (repeat an end point for the first / last segment).
static func catmull(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: float) -> Vector3:
	var t0 := 0.0
	var t1 := t0 + _knot(p0, p1)
	var t2 := t1 + _knot(p1, p2)
	var t3 := t2 + _knot(p2, p3)
	if t2 - t1 < 1e-6:
		return p1
	var tt := lerpf(t1, t2, t)
	var a1 := _mix(p0, p1, t0, t1, tt)
	var a2 := _mix(p1, p2, t1, t2, tt)
	var a3 := _mix(p2, p3, t2, t3, tt)
	var b1 := _mix(a1, a2, t0, t2, tt)
	var b2 := _mix(a2, a3, t1, t3, tt)
	return _mix(b1, b2, t1, t2, tt)


static func _knot(a: Vector3, b: Vector3) -> float:
	return maxf(sqrt(a.distance_to(b)), 1e-4)


static func _mix(a: Vector3, b: Vector3, ta: float, tb: float, t: float) -> Vector3:
	if tb - ta < 1e-9:
		return a
	return a.lerp(b, (t - ta) / (tb - ta))


## The point at spline parameter `s` in 0..n-1 (segment = floor(s)).
static func at(pts: PackedVector3Array, s: float) -> Vector3:
	var n := pts.size()
	if n == 0:
		return Vector3.ZERO
	if n == 1:
		return pts[0]
	s = clampf(s, 0.0, float(n - 1))
	var i := mini(int(s), n - 2)
	var f := s - float(i)
	var p0 := pts[maxi(i - 1, 0)]
	var p3 := pts[mini(i + 2, n - 1)]
	return catmull(p0, pts[i], pts[i + 1], p3, f)


## Cumulative arc length at evenly spaced parameters: {s: [...], d: [...]}.
static func arc_table(pts: PackedVector3Array) -> Dictionary:
	var ss := PackedFloat64Array()
	var dd := PackedFloat64Array()
	var segs := maxi(pts.size() - 1, 0)
	var steps := maxi(segs * SAMPLES_PER_SEGMENT, 1)
	var prev := at(pts, 0.0)
	var total := 0.0
	for k in steps + 1:
		var s := float(segs) * float(k) / float(steps)
		var p := at(pts, s)
		total += p.distance_to(prev)
		prev = p
		ss.append(s)
		dd.append(total)
	return {"s": ss, "d": dd}


## The spline parameter at arc length `d` (linear between table rows).
static func param_at(table: Dictionary, d: float) -> float:
	var ss: PackedFloat64Array = table["s"]
	var dd: PackedFloat64Array = table["d"]
	if ss.size() < 2:
		return 0.0
	var total := dd[dd.size() - 1]
	if total <= 1e-6:
		return ss[ss.size() - 1] * clampf(d, 0.0, 1.0)
	d = clampf(d, 0.0, total)
	var lo := 0
	var hi := dd.size() - 1
	while hi - lo > 1:
		var mid := (lo + hi) >> 1
		if dd[mid] < d:
			lo = mid
		else:
			hi = mid
	var span := dd[hi] - dd[lo]
	var f := 0.0 if span <= 1e-9 else (d - dd[lo]) / span
	return lerpf(ss[lo], ss[hi], f)


## Share of the way along at time share `u` (0..1) for a speed profile that
## accelerates over the first `accel` of the time, cruises, and decelerates
## over the last `accel` (0.5 = no cruise: quadratic ease in-out).
static func ease_trapezoid(u: float, accel: float = 0.25) -> float:
	u = clampf(u, 0.0, 1.0)
	var a := clampf(accel, 0.01, 0.5)
	var v := 1.0 / (1.0 - a)
	if u < a:
		return v * u * u / (2.0 * a)
	if u > 1.0 - a:
		var w := 1.0 - u
		return 1.0 - v * w * w / (2.0 * a)
	return v * (u - a * 0.5)
