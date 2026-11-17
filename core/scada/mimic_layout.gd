class_name MimicLayout
extends RefCounted
## Geometry helpers of the 2D process picture (plans/SCADA_PROCESS_PLAN.md,
## Phase 2). Pure.
##
## • `Proj`: 3D assembly millimetres → 2D picture units (also mm). A
##   side elevation with the depth axis drawn up and to the right at
##   `DEPTH_K` (a cabinet oblique), so height reads as height (gravity is
##   down the page), a run of pipe keeps its length, and what stands behind
##   something is drawn beside it instead of on it.
## • `reroute`: a line after the things at its ends were dragged, kept to
##   straight legs and right-angle bends (`connector` when it must be drawn
##   afresh; `simplify_corners` turns a drawn pipe into its legs).
## • `warp`: the older rubber-sheet field (kept; the canvas no longer uses it).

## Depth (the horizontal axis the view looks along) per unit drawn across / up.
const DEPTH_K := 0.38
## A pin's pull reaches this many radii.
const FALLOFF := 3.0


class Proj:
	extends RefCounted
	## Unit vectors in the assembly frame: `across` (drawn along +x), `depth`.
	var across := Vector3.RIGHT
	var depth := Vector3.BACK
	var origin := Vector3.ZERO

	func to_2d(v: Vector3) -> Vector2:
		var p := v - origin
		var a := p.dot(across)
		var d := p.dot(depth)
		return Vector2(a + d * MimicLayout.DEPTH_K, -p.y - d * MimicLayout.DEPTH_K)

	## How far back a point is (for draw order: far first).
	func depth_of(v: Vector3) -> float:
		return (v - origin).dot(depth)


## The projection for a cloud of points: across = the horizontal axis (x or
## z) the points spread most along, so a run of equipment reads left to right.
static func projection_for(points: PackedVector3Array) -> Proj:
	var pr := Proj.new()
	if points.is_empty():
		return pr
	var lo := points[0]
	var hi := points[0]
	var mean := Vector3.ZERO
	for p in points:
		lo = lo.min(p)
		hi = hi.max(p)
		mean += p
	mean /= float(points.size())
	# Spread = where most of the pipework is, not the one fitting furthest
	# out: the variance of the points (a long run has many).
	var vx := 0.0
	var vz := 0.0
	for p in points:
		vx += (p.x - mean.x) * (p.x - mean.x)
		vz += (p.z - mean.z) * (p.z - mean.z)
	if vz > vx * 1.15:
		pr.across = Vector3.BACK
		pr.depth = Vector3.LEFT
	else:
		pr.across = Vector3.RIGHT
		pr.depth = Vector3.FORWARD
	pr.origin = Vector3((lo.x + hi.x) * 0.5, lo.y, (lo.z + hi.z) * 0.5)
	return pr


## How much of a pin's move a point `dist` from its middle takes (1 inside
## the radius, smoothly to 0 at FALLOFF radii).
static func pin_weight(dist: float, r: float) -> float:
	var rr := maxf(r, 1.0)
	if dist <= rr:
		return 1.0
	var t := clampf((dist - rr) / (rr * (FALLOFF - 1.0)), 0.0, 1.0)
	return 1.0 - t * t * (3.0 - 2.0 * t)


## `p` moved by the pins ([{c: Vector2, r: float, off: Vector2}]). Where
## several pins overlap, their pulls are shared out so the total weight never
## passes 1 (a point between two dragged things goes somewhere between).
static func warp(p: Vector2, pins: Array) -> Vector2:
	if pins.is_empty():
		return p
	var sum := Vector2.ZERO
	var wsum := 0.0
	for pin in pins:
		var w := pin_weight(p.distance_to(pin["c"] as Vector2), float(pin["r"]))
		if w > 0.0:
			sum += (pin["off"] as Vector2) * w
			wsum += w
	if wsum <= 0.0:
		return p
	return p + (sum / wsum if wsum > 1.0 else sum)


static func warp_line(pts: PackedVector2Array, pins: Array) -> PackedVector2Array:
	if pins.is_empty():
		return pts
	var out := PackedVector2Array()
	out.resize(pts.size())
	for i in pts.size():
		out[i] = warp(pts[i], pins)
	return out


## A polyline with points every `step` at most (so a long straight pipe bends
## smoothly through the warp instead of staying a chord).
static func densify(pts: PackedVector2Array, step: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	if pts.is_empty():
		return out
	out.append(pts[0])
	for i in range(1, pts.size()):
		var a := pts[i - 1]
		var b := pts[i]
		var n := int(ceil(a.distance_to(b) / maxf(step, 1.0)))
		for k in range(1, n + 1):
			out.append(a.lerp(b, float(k) / float(n)))
	return out


static func length_of(pts: PackedVector2Array) -> float:
	var l := 0.0
	for i in range(1, pts.size()):
		l += pts[i - 1].distance_to(pts[i])
	return l


## The point `s` along a polyline and the direction there: [pos, dir].
static func point_at(pts: PackedVector2Array, s: float) -> Array:
	if pts.size() < 2:
		return [pts[0] if pts.size() == 1 else Vector2.ZERO, Vector2.RIGHT]
	var left := maxf(s, 0.0)
	for i in range(1, pts.size()):
		var seg := pts[i - 1].distance_to(pts[i])
		if left <= seg or i == pts.size() - 1:
			var d := (pts[i] - pts[i - 1])
			var dir := d.normalized() if seg > 1e-6 else Vector2.RIGHT
			return [pts[i - 1] + dir * minf(left, seg), dir]
		left -= seg
	return [pts[pts.size() - 1], Vector2.RIGHT]


## Distance from `p` to a polyline.
static func distance_to_line(p: Vector2, pts: PackedVector2Array) -> float:
	var best := INF
	for i in range(1, pts.size()):
		var c := Geometry2D.get_closest_point_to_segment(p, pts[i - 1], pts[i])
		best = minf(best, p.distance_to(c))
	if pts.size() == 1:
		best = p.distance_to(pts[0])
	return best


## Bounds of a picture: every pipe point and element rect.
static func bounds_of(doc: Dictionary) -> Rect2:
	var have := false
	var r := Rect2()
	for pipe in doc.get("pipes", []):
		for p in (pipe["pts"] as PackedVector2Array):
			if not have:
				r = Rect2(p, Vector2.ZERO)
				have = true
			else:
				r = r.expand(p)
	for e in doc.get("elements", []):
		var er := Rect2((e["pos"] as Vector2) - (e["size"] as Vector2) * 0.5, e["size"] as Vector2)
		if not have:
			r = er
			have = true
		else:
			r = r.merge(er)
	return r if have else Rect2(-100, -100, 200, 200)


# ── orthogonal re-routing (moved things keep tidy right-angle pipes) ────────

## A pipe's route after the things at its ends moved by `da` (start) and
## `db` (end). `corners` = the route's corner points (no rounding). Every
## segment keeps its direction: the first segment slides through the moved
## start, the last through the moved end, the ones between stay where they
## are, and each corner is where two neighbouring segments now meet. A
## straight run whose ends move apart sideways gets a jog in the middle; a
## run that would fold back on itself is routed afresh (`connector`), out of
## the start and into the end the way the pipe left and arrived. `stub` = the
## least run kept straight out of an end. Pure.
static func reroute(corners: PackedVector2Array, da: Vector2, db: Vector2, stub: float) -> PackedVector2Array:
	var c := clean_corners(corners)
	if c.size() < 2 or da.distance_to(db) < 0.01:
		var same := PackedVector2Array()
		for p in c:
			same.append(p + da)
		return same
	var n := c.size() - 1
	var a2 := c[0] + da
	var b2 := c[n] + db
	var u: Array = []
	var nr: Array = []
	var len0: Array = []
	for k in n:
		var d := c[k + 1] - c[k]
		var l := d.length()
		var uk := d / l
		u.append(uk)
		nr.append(Vector2(-uk.y, uk.x))
		len0.append(l)
	var u_out: Vector2 = u[0]
	var u_in: Vector2 = u[n - 1]
	if n == 1:
		var delta := b2 - a2
		if absf(delta.cross(u_out)) < 0.5:
			if delta.dot(u_out) > 0.0:
				return PackedVector2Array([a2, b2])
			return connector(a2, u_out, b2, u_in, stub)
		var j := _jog_axis(u_out)
		var det := u_out.cross(j)
		var along := delta.cross(j) / det
		var side := u_out.cross(delta) / det
		if along < stub * 2.0:
			return connector(a2, u_out, b2, u_in, stub)
		var m1 := a2 + u_out * (along * 0.5)
		return PackedVector2Array([a2, m1, m1 + j * side, b2])
	# Each segment's line: through c[k] shifted s[k] along its normal.
	var s := PackedFloat64Array()
	s.resize(n)
	s[0] = da.dot(nr[0])
	s[n - 1] = db.dot(nr[n - 1])
	var v := _corners_of(c, u, nr, s, a2, b2)
	if n >= 3:
		# The runs out of the ends stay at least a stub long (or as long as
		# they were): the segment next to an end slides to make room.
		var need0 := minf(stub, float(len0[0]))
		var l0 := (v[1] - v[0]).dot(u[0])
		var k1: float = (nr[1] as Vector2).dot(u[0])
		if l0 < need0 and absf(k1) > 0.3:
			s[1] += (need0 - l0) * k1
			v = _corners_of(c, u, nr, s, a2, b2)
		var needn := minf(stub, float(len0[n - 1]))
		var ln := (v[n] - v[n - 1]).dot(u[n - 1])
		var kn: float = (nr[n - 2] as Vector2).dot(u[n - 1])
		if ln < needn and absf(kn) > 0.3:
			s[n - 2] -= (needn - ln) * kn
			v = _corners_of(c, u, nr, s, a2, b2)
	# A segment that now runs backwards (or ends that lost their stubs):
	# route it afresh.
	for k in n:
		if not v[k].is_finite() or not v[k + 1].is_finite():
			return connector(a2, u_out, b2, u_in, stub)
		var lk := (v[k + 1] - v[k]).dot(u[k])
		var floor_k := 0.5
		if k == 0 or k == n - 1:
			floor_k = minf(stub, float(len0[k])) * 0.5
		if lk < floor_k and float(len0[k]) > 1.0:
			return connector(a2, u_out, b2, u_in, stub)
	return clean_corners(v)


static func _corners_of(c: PackedVector2Array, u: Array, nr: Array, s: PackedFloat64Array, a2: Vector2, b2: Vector2) -> PackedVector2Array:
	var n := c.size() - 1
	var v := PackedVector2Array()
	v.resize(n + 1)
	v[0] = a2
	v[n] = b2
	for k in range(1, n):
		var p0: Vector2 = c[k - 1] + (nr[k - 1] as Vector2) * s[k - 1]
		var p1: Vector2 = c[k] + (nr[k] as Vector2) * s[k]
		v[k] = line_cross(p0, u[k - 1], p1, u[k])
	return v


## Where two lines (point + direction) meet; INF when they are parallel.
static func line_cross(p: Vector2, du: Vector2, q: Vector2, dv: Vector2) -> Vector2:
	var den := du.cross(dv)
	if absf(den) < 1e-4:
		return Vector2.INF
	var t := (q - p).cross(dv) / den
	return p + du * t


## The picture axis most across a run's direction (where its jog goes).
static func _jog_axis(dir: Vector2) -> Vector2:
	return Vector2.DOWN if absf(dir.x) >= absf(dir.y) else Vector2.RIGHT


static func _axis(dir: Vector2) -> Vector2:
	if absf(dir.x) >= absf(dir.y):
		return Vector2(1.0 if dir.x >= 0.0 else -1.0, 0.0)
	return Vector2(0.0, 1.0 if dir.y >= 0.0 else -1.0)


## A fresh right-angle route from `a` (leaving along `out_dir`) to `b`
## (arriving along `in_dir`), at least `stub` straight out of each end.
## Directions snap to the picture's axes. Pure.
static func connector(a: Vector2, out_dir: Vector2, b: Vector2, in_dir: Vector2, stub: float) -> PackedVector2Array:
	var uo := _axis(out_dir)
	var ui := _axis(in_dir)
	var p1 := a + uo * stub
	var p2 := b - ui * stub
	var pts := PackedVector2Array([a])
	var horiz := absf(uo.x) > 0.5
	if absf(uo.dot(ui)) > 0.5:
		if uo.dot(ui) > 0.0:
			if (p2 - p1).dot(uo) >= 0.0:
				# Ahead: one riser half way.
				var m := (a + b) * 0.5
				if horiz:
					pts.append_array([Vector2(m.x, a.y), Vector2(m.x, b.y)])
				else:
					pts.append_array([Vector2(a.x, m.y), Vector2(b.x, m.y)])
			else:
				# Behind: out, across half way between (or round below), back, in.
				var q := 0.0
				if horiz:
					q = (a.y + b.y) * 0.5 if absf(a.y - b.y) > stub * 2.0 else maxf(a.y, b.y) + stub * 2.0
					pts.append_array([p1, Vector2(p1.x, q), Vector2(p2.x, q), p2])
				else:
					q = (a.x + b.x) * 0.5 if absf(a.x - b.x) > stub * 2.0 else maxf(a.x, b.x) + stub * 2.0
					pts.append_array([p1, Vector2(q, p1.y), Vector2(q, p2.y), p2])
		else:
			# Out and back in the other way: a U past the further of the two.
			if horiz:
				var mx := maxf(p1.x, p2.x) if uo.x > 0.0 else minf(p1.x, p2.x)
				pts.append_array([Vector2(mx, a.y), Vector2(mx, b.y)])
			else:
				var my := maxf(p1.y, p2.y) if uo.y > 0.0 else minf(p1.y, p2.y)
				pts.append_array([Vector2(a.x, my), Vector2(b.x, my)])
	else:
		# Across each other: one corner if both runs fit, else through the stubs.
		var corner := Vector2(b.x, a.y) if horiz else Vector2(a.x, b.y)
		if (corner - a).dot(uo) >= stub and (b - corner).dot(ui) >= stub:
			pts.append(corner)
		else:
			pts.append(p1)
			pts.append(Vector2(p1.x, p2.y) if horiz else Vector2(p2.x, p1.y))
			pts.append(p2)
	pts.append(b)
	return clean_corners(pts)


## Corner points without repeats or straight-through points.
static func clean_corners(pts: PackedVector2Array) -> PackedVector2Array:
	var a := PackedVector2Array()
	for p in pts:
		if a.is_empty() or a[a.size() - 1].distance_to(p) > 0.5:
			a.append(p)
	if a.size() < 3:
		return a
	var out := PackedVector2Array([a[0]])
	for i in range(1, a.size() - 1):
		var d0 := (a[i] - out[out.size() - 1]).normalized()
		var d1 := (a[i + 1] - a[i]).normalized()
		if absf(d0.cross(d1)) < 0.035 and d0.dot(d1) > 0.0:
			continue
		out.append(a[i])
	out.append(a[a.size() - 1])
	return out


## A drawn path (a real pipe's centre line, bends sampled as arcs) as the
## corners of straight runs: Ramer–Douglas–Peucker within `tol`, then each
## short chamfer an arc left between two runs turned into the corner where
## those runs meet. Pure.
static func simplify_corners(pts: PackedVector2Array, tol: float) -> PackedVector2Array:
	var c := clean_corners(pts)
	if c.size() < 3:
		return c
	var keep := PackedByteArray()
	keep.resize(c.size())
	keep[0] = 1
	keep[c.size() - 1] = 1
	_rdp(c, 0, c.size() - 1, maxf(tol, 0.5), keep)
	var r := PackedVector2Array()
	for i in c.size():
		if keep[i] == 1:
			r.append(c[i])
	var changed := true
	var guard := 0
	while changed and guard < 64:
		changed = false
		guard += 1
		# A chain of short chords r[i]..r[j] between the leg into r[i] and the
		# leg out of r[j]: the bend. Replaced by where those two legs meet
		# (the chain whose leg out is longest, so the whole arc goes).
		for i in range(1, r.size() - 1):
			var d0 := r[i] - r[i - 1]
			if d0.length() < 1e-3:
				continue
			var chain := 0.0
			var best_j := -1
			var best_x := Vector2.INF
			var best_len := -1.0
			for j in range(i + 1, r.size() - 1):
				chain += r[j - 1].distance_to(r[j])
				if chain > tol * 10.0:
					break
				var d1 := r[j + 1] - r[j]
				if d1.length() < 1e-3 or absf(d0.normalized().cross(d1.normalized())) < 0.5:
					continue
				var x := line_cross(r[i - 1], d0.normalized(), r[j], d1.normalized())
				if not x.is_finite() or x.distance_to((r[i] + r[j]) * 0.5) > tol * 6.0:
					continue
				if d1.length() > best_len:
					best_len = d1.length()
					best_j = j
					best_x = x
			if best_j < 0:
				continue
			r[i] = best_x
			for _k in best_j - i:
				r.remove_at(i + 1)
			changed = true
			break
	return clean_corners(r)


static func _rdp(c: PackedVector2Array, i0: int, i1: int, tol: float, keep: PackedByteArray) -> void:
	if i1 <= i0 + 1:
		return
	var best := -1.0
	var bi := -1
	for i in range(i0 + 1, i1):
		var q := Geometry2D.get_closest_point_to_segment(c[i], c[i0], c[i1])
		var d := c[i].distance_to(q)
		if d > best:
			best = d
			bi = i
	if best > tol:
		keep[bi] = 1
		_rdp(c, i0, bi, tol, keep)
		_rdp(c, bi, i1, tol, keep)


## A polyline with its corners turned into arcs of radius `r` (less where a
## leg is short).
static func round_corners(pts: PackedVector2Array, r: float) -> PackedVector2Array:
	if pts.size() < 3 or r <= 0.0:
		return pts
	var out := PackedVector2Array([pts[0]])
	for i in range(1, pts.size() - 1):
		var p := pts[i]
		var d0 := pts[i - 1] - p
		var d1 := pts[i + 1] - p
		var l0 := d0.length()
		var l1 := d1.length()
		if l0 < 1e-3 or l1 < 1e-3:
			continue
		var rr := minf(r, minf(l0, l1) * 0.5)
		var a := p + d0 / l0 * rr
		var b := p + d1 / l1 * rr
		for k in 7:
			var t := float(k) / 6.0
			# Quadratic curve through the corner: close to an arc, no trig.
			out.append(a.lerp(p, t).lerp(p.lerp(b, t), t))
	out.append(pts[pts.size() - 1])
	return out
