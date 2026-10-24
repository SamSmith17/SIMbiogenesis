class_name FlatpackProfile
extends RefCounted

## Part outlines for the flat-pack furniture designer, with TRUE ARCS.
##
## A ring is {pts: PackedVector2Array, bulge: PackedFloat64Array}: segment i
## runs from pts[i] to pts[(i + 1) % n] and bends by bulge[i], the DXF
## convention (bulge = tan(sweep / 4), positive = counter-clockwise, 0 =
## straight). Fillets, dogbones and arches stay arcs all the way to the CNC
## file; only the 3D mesh and the polygon tests tessellate them.
##
## Units are INCHES throughout (the router, the plywood and the sample design
## are all imperial); the mesh builder converts to metres.
##
## A part is built from a BASE polygon (straight edges, counter-clockwise),
## one fillet radius per vertex and a list of EDGE NOTCHES (the slots the joint
## solver finds). `ring_from_base` lays the notches into their edges and rounds
## the corners, shrinking a corner's radius when a slot sits too close to it,
## so the solver never has to know about fillets. Holes (mortises, wedge
## holes) are separate clockwise rings.
##
## Inside corners: a router bit cannot cut a sharp inside corner, so the
## bottom corners of every slot and every corner of a hole get relief:
##   "dogbone" — a circle of the bit's radius on the corner's bisector through
##               the corner (overcuts both walls a little; the classic);
##   "tbone"   — the same circle moved along the slot's depth axis, so it
##               overcuts only sideways (the slot bottom stays flat);
##   "none"    — sharp (laser, hand saw, or a model like the sample's).

const EPS := 1e-6
## Tessellation: the longest chord and the largest angle a tessellated arc
## segment may span.
const ARC_MAX_SEG := 0.25
const ARC_MAX_ANGLE := deg_to_rad(10.0)

const RELIEF_STYLES := ["dogbone", "tbone", "none"]


# ---------------------------------------------------------------------------
# Rings
# ---------------------------------------------------------------------------

static func make_ring(pts: PackedVector2Array, bulge: PackedFloat64Array = PackedFloat64Array()) -> Dictionary:
	var b := bulge
	if b.size() != pts.size():
		b = PackedFloat64Array()
		b.resize(pts.size())
		b.fill(0.0)
	return {"pts": pts, "bulge": b}


static func rect_ring(w: float, h: float, origin: Vector2 = Vector2.ZERO) -> Dictionary:
	return make_ring(PackedVector2Array([origin, origin + Vector2(w, 0), origin + Vector2(w, h),
		origin + Vector2(0, h)]))


## A full circle as two half-circle arcs (bulge 1 each), centred on `c`.
static func circle_ring(c: Vector2, r: float) -> Dictionary:
	return make_ring(PackedVector2Array([c + Vector2(r, 0), c + Vector2(-r, 0)]),
		PackedFloat64Array([1.0, 1.0]))


static func ring_size(ring: Dictionary) -> int:
	return (ring.get("pts", PackedVector2Array()) as PackedVector2Array).size()


## Translate / rotate a ring (rotation keeps every bulge; it preserves turn
## direction). `rot` is radians about the origin, applied before `offset`.
static func transform_ring(ring: Dictionary, rot: float, offset: Vector2) -> Dictionary:
	var pts: PackedVector2Array = ring["pts"]
	var out := PackedVector2Array()
	out.resize(pts.size())
	for i in pts.size():
		out[i] = pts[i].rotated(rot) + offset
	return make_ring(out, (ring["bulge"] as PackedFloat64Array).duplicate())


## Mirror across the y axis (x -> -x). Mirroring flips every arc's direction
## and the ring's winding; the ring is reversed so it keeps its winding.
static func mirror_ring_x(ring: Dictionary) -> Dictionary:
	var pts: PackedVector2Array = ring["pts"]
	var bul: PackedFloat64Array = ring["bulge"]
	var n := pts.size()
	var out := PackedVector2Array()
	var ob := PackedFloat64Array()
	out.resize(n)
	ob.resize(n)
	# Reversed order: new segment k runs from old point (n-1-k)... to old (n-2-k),
	# i.e. old segment (n-2-k) backwards; mirrored and reversed = same sign.
	for k in n:
		var oi := (n - 1 - k) % n
		out[k] = Vector2(-pts[oi].x, pts[oi].y)
	for k in n:
		var seg := (n - 2 - k + n) % n
		ob[k] = bul[seg]
	return make_ring(out, ob)


# ---------------------------------------------------------------------------
# Arcs
# ---------------------------------------------------------------------------

## Centre and radius of the arc from `a` to `b` with `bulge` (bulge != 0).
static func arc_center(a: Vector2, b: Vector2, bulge: float) -> Vector2:
	var c := b - a
	var left := Vector2(-c.y, c.x)
	return (a + b) * 0.5 + left * ((1.0 - bulge * bulge) / (4.0 * bulge))


static func arc_points(a: Vector2, b: Vector2, bulge: float, max_seg: float = ARC_MAX_SEG,
		max_angle: float = ARC_MAX_ANGLE) -> PackedVector2Array:
	## Points from `a` (included) toward `b` (excluded) along the segment.
	var out := PackedVector2Array([a])
	if absf(bulge) < EPS or a.distance_to(b) < EPS:
		return out
	var sweep := 4.0 * atan(bulge)
	var cen := arc_center(a, b, bulge)
	var r := cen.distance_to(a)
	var steps := maxi(2, int(ceil(maxf(absf(sweep) / max_angle, absf(sweep) * r / maxf(max_seg, 0.01)))))
	var a0 := (a - cen).angle()
	for k in range(1, steps):
		var t := a0 + sweep * float(k) / float(steps)
		out.append(cen + Vector2(cos(t), sin(t)) * r)
	return out


static func arc_length(a: Vector2, b: Vector2, bulge: float) -> float:
	if absf(bulge) < EPS:
		return a.distance_to(b)
	var sweep := absf(4.0 * atan(bulge))
	return arc_center(a, b, bulge).distance_to(a) * sweep


## The bulge of the arc from `s` to `e` around centre `c` that passes the side
## of the circle where `m` is.
static func bulge_via(s: Vector2, m: Vector2, e: Vector2, c: Vector2) -> float:
	var a0 := (s - c).angle()
	var d := fposmod((e - c).angle() - a0, TAU)
	var dm := fposmod((m - c).angle() - a0, TAU)
	var sweep := d if dm <= d else d - TAU
	return tan(sweep / 4.0)


## Tessellated outline (closed; the first point is not repeated).
static func tessellate(ring: Dictionary, max_seg: float = ARC_MAX_SEG) -> PackedVector2Array:
	var pts: PackedVector2Array = ring.get("pts", PackedVector2Array())
	var bul: PackedFloat64Array = ring.get("bulge", PackedFloat64Array())
	var out := PackedVector2Array()
	var n := pts.size()
	for i in n:
		var b := bul[i] if i < bul.size() else 0.0
		out.append_array(arc_points(pts[i], pts[(i + 1) % n], b, max_seg))
	return out


static func perimeter(ring: Dictionary) -> float:
	var pts: PackedVector2Array = ring["pts"]
	var bul: PackedFloat64Array = ring["bulge"]
	var total := 0.0
	for i in pts.size():
		total += arc_length(pts[i], pts[(i + 1) % pts.size()], bul[i])
	return total


static func signed_area(poly: PackedVector2Array) -> float:
	var a := 0.0
	var n := poly.size()
	for i in n:
		var p := poly[i]
		var q := poly[(i + 1) % n]
		a += p.x * q.y - q.x * p.y
	return a * 0.5


static func area(ring: Dictionary) -> float:
	return absf(signed_area(tessellate(ring)))


static func bbox(poly: PackedVector2Array) -> Rect2:
	if poly.is_empty():
		return Rect2()
	var mn := poly[0]
	var mx := poly[0]
	for p in poly:
		mn = Vector2(minf(mn.x, p.x), minf(mn.y, p.y))
		mx = Vector2(maxf(mx.x, p.x), maxf(mx.y, p.y))
	return Rect2(mn, mx - mn)


static func ring_bbox(ring: Dictionary) -> Rect2:
	return bbox(tessellate(ring))


static func is_ccw(poly: PackedVector2Array) -> bool:
	return signed_area(poly) > 0.0


## True when no two non-adjacent segments of the polygon cross.
static func is_simple(poly: PackedVector2Array) -> bool:
	var n := poly.size()
	if n < 3:
		return false
	for i in n:
		var a := poly[i]
		var b := poly[(i + 1) % n]
		for j in range(i + 2, n):
			if i == 0 and j == n - 1:
				continue
			var c := poly[j]
			var d := poly[(j + 1) % n]
			if Geometry2D.segment_intersects_segment(a, b, c, d) != null:
				return false
	return true


# ---------------------------------------------------------------------------
# Corners
# ---------------------------------------------------------------------------

## Turn from direction `a` to direction `b`: radians, signed (+ = left / CCW).
static func turn_angle(a: Vector2, b: Vector2) -> float:
	return atan2(a.x * b.y - a.y * b.x, a.dot(b))


## A fillet at vertex `v` between incoming direction `a` and outgoing `b`
## (unit vectors). Returns {t_in, t_out, bulge, d} or {} when straight.
static func fillet(v: Vector2, a: Vector2, b: Vector2, r: float) -> Dictionary:
	var phi := turn_angle(a, b)
	if r <= EPS or absf(phi) < 1e-4:
		return {}
	var d := r * tan(absf(phi) * 0.5)
	return {"t_in": v - a * d, "t_out": v + b * d, "bulge": tan(phi / 4.0), "d": d}


## Tangent length a fillet of radius `r` needs on each wall at a corner that
## turns by `phi`.
static func fillet_tangent(phi: float, r: float) -> float:
	return r * tan(absf(phi) * 0.5)


## Relief at an INSIDE corner `v` (incoming direction `a`, outgoing `b`) for a
## bit of radius `r`. `centre_offset` puts the cutter's centre (|offset| = r);
## the arc runs from where the circle leaves the incoming wall to where it
## meets the outgoing wall, the long way round through the material. Appends
## (point, bulge) pairs to `out` and returns nothing. A point equal to `v`
## itself is appended once.
static func corner_relief(v: Vector2, a: Vector2, b: Vector2, centre_offset: Vector2,
		out_pts: PackedVector2Array, out_bul: PackedFloat64Array) -> void:
	var r := centre_offset.length()
	var c := v + centre_offset
	var s := -2.0 * a.dot(centre_offset)
	var u := 2.0 * b.dot(centre_offset)
	var q1 := v - a * maxf(s, 0.0)
	var q2 := v + b * maxf(u, 0.0)
	var waste := (b - a).normalized()
	var m := c - waste * r
	if q1.distance_to(q2) < EPS:
		out_pts.append(v)
		out_bul.append(0.0)
		return
	out_pts.append(q1)
	out_bul.append(bulge_via(q1, m, q2, c))
	out_pts.append(q2)
	out_bul.append(0.0)


# ---------------------------------------------------------------------------
# Building a part outline
# ---------------------------------------------------------------------------

## A notch (slot) in edge `edge` of the base polygon:
##   at     — distance along the edge from base[edge] to the slot's centre line
##            where it meets the edge;
##   width  — across the slot (perpendicular to its depth axis);
##   depth  — from the edge point `at` along `dir`;
##   dir    — the slot's depth axis (unit, pointing into the part); omitted =
##            square to the edge;
##   inner_r — round the two bottom corners at this radius instead of relief
##            (an arch: the foot cut-out of a leg);
##   entry_r — round the two corners where the slot meets the edge.
static func make_notch(edge: int, at: float, width: float, depth: float,
		dir: Vector2 = Vector2.ZERO, extra: Dictionary = {}) -> Dictionary:
	var n := {"edge": edge, "at": at, "width": width, "depth": depth, "dir": dir}
	n.merge(extra, true)
	return n


## The outline of a part: `base` (CCW, straight edges) with a fillet of
## `corner_r[i]` at vertex i and `notches` laid into their edges.
## opts: relief ("dogbone" | "tbone" | "none"), bit_r (inches).
## Returns {ring, warnings: [String]}.
static func ring_from_base(base: PackedVector2Array, corner_r: PackedFloat64Array,
		notches: Array, opts: Dictionary = {}) -> Dictionary:
	var warnings: Array = []
	var n := base.size()
	if n < 3:
		return {"ring": make_ring(base), "warnings": ["outline has fewer than 3 corners"]}
	var relief := str(opts.get("relief", "dogbone"))
	var bit_r := float(opts.get("bit_r", 0.125))

	# Notch openings per edge, sorted along the edge.
	var per_edge: Array = []
	per_edge.resize(n)
	for i in n:
		per_edge[i] = []
	for nt in notches:
		var e := int(nt.get("edge", -1))
		if e < 0 or e >= n:
			warnings.append("a slot is on an edge that does not exist")
			continue
		var g := _notch_geometry(base, e, nt)
		if g.is_empty():
			warnings.append("a slot could not be laid into its edge")
			continue
		(per_edge[e] as Array).append(g)
	for i in n:
		(per_edge[i] as Array).sort_custom(func(x, y): return float(x["s0"]) < float(y["s0"]))

	# Drop slots that overlap an earlier one on the same edge.
	for i in n:
		var kept: Array = []
		var last_end := -INF
		for g in per_edge[i]:
			if float(g["s0"]) < last_end - 1e-4:
				warnings.append("two slots overlap on one edge; the second was left out")
				continue
			kept.append(g)
			last_end = float(g["s1"])
		per_edge[i] = kept

	# Room for each corner's fillet: up to the nearest slot opening on each of
	# its two edges, and at most half of each edge (shared with the next corner).
	var dirs: Array = []
	var lens := PackedFloat64Array()
	for i in n:
		var d := base[(i + 1) % n] - base[i]
		lens.append(d.length())
		dirs.append(d.normalized() if d.length() > EPS else Vector2.RIGHT)
	var radii := PackedFloat64Array()
	radii.resize(n)
	for i in n:
		var r := corner_r[i] if i < corner_r.size() else 0.0
		if r <= EPS:
			radii[i] = 0.0
			continue
		var prev := (i - 1 + n) % n
		var phi := turn_angle(dirs[prev], dirs[i])
		if absf(phi) < 1e-4:
			radii[i] = 0.0
			continue
		var room_out := lens[i] * 0.5
		if not (per_edge[i] as Array).is_empty():
			room_out = minf(room_out, float((per_edge[i] as Array)[0]["s0"]) - 0.05)
		var room_in := lens[prev] * 0.5
		if not (per_edge[prev] as Array).is_empty():
			room_in = minf(room_in, lens[prev] - float((per_edge[prev] as Array).back()["s1"]) - 0.05)
		var d_max := maxf(minf(room_out, room_in), 0.0)
		var t := tan(absf(phi) * 0.5)
		var r_fit := d_max / t if t > EPS else 0.0
		if r_fit + 1e-4 < r:
			r = maxf(r_fit, 0.0)
		radii[i] = r

	var pts := PackedVector2Array()
	var bul := PackedFloat64Array()
	for i in n:
		var prev := (i - 1 + n) % n
		var f := fillet(base[i], dirs[prev], dirs[i], radii[i])
		if f.is_empty():
			pts.append(base[i])
			bul.append(0.0)
		else:
			pts.append(f["t_in"])
			bul.append(float(f["bulge"]))
			pts.append(f["t_out"])
			bul.append(0.0)
		for g in per_edge[i]:
			_emit_notch(g, relief, bit_r, pts, bul, warnings)
	return {"ring": _clean(make_ring(pts, bul)), "warnings": warnings}


## Where a notch meets its edge: the two wall/edge crossings (as distances
## along the edge) and the four path points.
static func _notch_geometry(base: PackedVector2Array, e: int, nt: Dictionary) -> Dictionary:
	var a := base[e]
	var b := base[(e + 1) % base.size()]
	var L := a.distance_to(b)
	if L < EPS:
		return {}
	var t := (b - a) / L
	var inward := Vector2(-t.y, t.x)   # CCW base: the part is on the left
	var u: Vector2 = nt.get("dir", Vector2.ZERO)
	if u.length() < EPS:
		u = inward
	u = u.normalized()
	if u.dot(inward) < 0.05:
		return {}
	var p := Vector2(u.y, -u.x)        # across the slot, along the edge side
	var w := float(nt.get("width", 0.5))
	var depth := float(nt.get("depth", 1.0))
	var c := a + t * float(nt.get("at", 0.0))
	# Each wall is the line c + p*k + u*s; it meets the edge where its
	# component along `inward` is zero.
	var k1 := -w * 0.5
	var k2 := w * 0.5
	var s1 := -(p * k1).dot(inward) / u.dot(inward)
	var s2 := -(p * k2).dot(inward) / u.dot(inward)
	var e1 := c + p * k1 + u * s1
	var e2 := c + p * k2 + u * s2
	var b1 := c + p * k1 + u * depth
	var b2 := c + p * k2 + u * depth
	var d1 := (e1 - a).dot(t)
	var d2 := (e2 - a).dot(t)
	if minf(d1, d2) < -1e-4 or maxf(d1, d2) > L + 1e-4:
		return {}
	if depth <= maxf(s1, s2) + 1e-4:
		return {}
	return {"s0": minf(d1, d2), "s1": maxf(d1, d2), "e1": e1, "e2": e2, "b1": b1, "b2": b2,
		"u": u, "p": p, "t": t, "w": w,
		"inner_r": float(nt.get("inner_r", 0.0)), "entry_r": float(nt.get("entry_r", 0.0))}


static func _emit_notch(g: Dictionary, relief: String, bit_r: float,
		pts: PackedVector2Array, bul: PackedFloat64Array, warnings: Array) -> void:
	var u: Vector2 = g["u"]
	var p: Vector2 = g["p"]
	var t: Vector2 = g["t"]
	var e1: Vector2 = g["e1"]
	var e2: Vector2 = g["e2"]
	var b1: Vector2 = g["b1"]
	var b2: Vector2 = g["b2"]
	var w := float(g["w"])
	var inner_r := float(g["inner_r"])
	var entry_r := float(g["entry_r"])
	var wall1 := b1.distance_to(e1)
	var wall2 := b2.distance_to(e2)

	# Entry corner 1: edge -> down wall 1.
	if entry_r > EPS:
		var f := fillet(e1, t, u, minf(entry_r, minf(wall1, w) * 0.45))
		if not f.is_empty():
			pts.append(f["t_in"])
			bul.append(float(f["bulge"]))
			pts.append(f["t_out"])
			bul.append(0.0)
		else:
			pts.append(e1)
			bul.append(0.0)
	else:
		pts.append(e1)
		bul.append(0.0)

	# Bottom corners.
	if inner_r > EPS:
		var r := minf(inner_r, minf(w * 0.5, minf(wall1, wall2)) * 0.98)
		var f1 := fillet(b1, u, p, r)
		var f2 := fillet(b2, p, -u, r)
		if not f1.is_empty():
			pts.append(f1["t_in"])
			bul.append(float(f1["bulge"]))
			pts.append(f1["t_out"])
			bul.append(0.0)
		if not f2.is_empty():
			pts.append(f2["t_in"])
			bul.append(float(f2["bulge"]))
			pts.append(f2["t_out"])
			bul.append(0.0)
	elif relief == "dogbone" and bit_r > EPS:
		if w < 2.0 * sqrt(2.0) * bit_r + 1e-4:
			warnings.append("a slot is too narrow for dogbones with this bit; T-bones used")
			_tbone_pair(b1, b2, u, p, bit_r, pts, bul)
		else:
			corner_relief(b1, u, p, (p - u).normalized() * bit_r, pts, bul)
			corner_relief(b2, p, -u, (-u - p).normalized() * bit_r, pts, bul)
	elif relief == "tbone" and bit_r > EPS:
		_tbone_pair(b1, b2, u, p, bit_r, pts, bul)
	else:
		pts.append(b1)
		bul.append(0.0)
		pts.append(b2)
		bul.append(0.0)

	# Exit corner: up wall 2 -> edge.
	if entry_r > EPS:
		var f := fillet(e2, -u, t, minf(entry_r, minf(wall2, w) * 0.45))
		if not f.is_empty():
			pts.append(f["t_in"])
			bul.append(float(f["bulge"]))
			pts.append(f["t_out"])
			bul.append(0.0)
			return
	pts.append(e2)
	bul.append(0.0)


## T-bones at the two bottom corners: the cutter centre backs up the depth
## axis by r, so the overcut goes sideways only.
static func _tbone_pair(b1: Vector2, b2: Vector2, u: Vector2, p: Vector2, r: float,
		pts: PackedVector2Array, bul: PackedFloat64Array) -> void:
	corner_relief(b1, u, p, -u * r, pts, bul)
	corner_relief(b2, p, -u, -u * r, pts, bul)


## Merge consecutive duplicate points (a relief arc that ends where the next
## corner starts).
static func _clean(ring: Dictionary) -> Dictionary:
	var pts: PackedVector2Array = ring["pts"]
	var bul: PackedFloat64Array = ring["bulge"]
	var op := PackedVector2Array()
	var ob := PackedFloat64Array()
	for i in pts.size():
		if not op.is_empty() and op[op.size() - 1].distance_to(pts[i]) < 1e-5:
			# Keep the bulge of the later segment (the earlier one had length 0).
			ob[ob.size() - 1] = bul[i]
			continue
		op.append(pts[i])
		ob.append(bul[i])
	if op.size() > 1 and op[0].distance_to(op[op.size() - 1]) < 1e-5:
		op.remove_at(op.size() - 1)
		ob.remove_at(ob.size() - 1)
	return make_ring(op, ob)


## A rectangular hole (mortise / wedge hole) centred on `c`, `length` along
## `axis` and `width` across it, wound CLOCKWISE (a hole), with relief at its
## four corners. T-bone relief overcuts along the hole's length.
static func hole_ring(c: Vector2, axis: Vector2, length: float, width: float,
		opts: Dictionary = {}) -> Dictionary:
	var relief := str(opts.get("relief", "dogbone"))
	var bit_r := float(opts.get("bit_r", 0.125))
	var ax := axis.normalized() if axis.length() > EPS else Vector2.RIGHT
	var cr := Vector2(-ax.y, ax.x)
	var hl := length * 0.5
	var hw := width * 0.5
	# Clockwise: +ax+cr, +ax-cr, -ax-cr, -ax+cr.
	var corners := [c + ax * hl + cr * hw, c + ax * hl - cr * hw, c - ax * hl - cr * hw,
		c - ax * hl + cr * hw]
	var pts := PackedVector2Array()
	var bul := PackedFloat64Array()
	for i in 4:
		var v: Vector2 = corners[i]
		var a: Vector2 = (v - corners[(i + 3) % 4]).normalized()
		var b: Vector2 = (corners[(i + 1) % 4] - v).normalized()
		if relief == "none" or bit_r <= EPS:
			pts.append(v)
			bul.append(0.0)
		elif relief == "tbone":
			# Centre moved across the hole (toward its centre line): the
			# overcut runs out along the hole's length.
			var towards := (c - v).dot(cr)
			corner_relief(v, a, b, cr * signf(towards) * bit_r, pts, bul)
		else:
			corner_relief(v, a, b, (b - a).normalized() * bit_r, pts, bul)
	return _clean(make_ring(pts, bul))


## Inside-corner count of a ring (for the selftest): corners that turn right
## in a CCW ring.
static func inside_corner_count(ring: Dictionary) -> int:
	var poly := tessellate(ring, 10.0)
	var n := poly.size()
	var count := 0
	for i in n:
		var a := poly[i] - poly[(i - 1 + n) % n]
		var b := poly[(i + 1) % n] - poly[i]
		if a.x * b.y - a.y * b.x < -1e-6:
			count += 1
	return count


## Point in a closed (tessellated) polygon, even-odd.
static func point_in_poly(p: Vector2, poly: PackedVector2Array) -> bool:
	return Geometry2D.is_point_in_polygon(p, poly)
