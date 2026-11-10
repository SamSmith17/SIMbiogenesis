class_name GraphSchema3D
extends RefCounted

## The ring arrangement (GraphSchemaLayout.ring) seen in 3D. Same three
## groups as the flat ring — machines outside, the stores they share inside,
## the people in the middle — placed in space instead of on circles:
##
##   sphere   a cell: the machines spread evenly over an outer sphere (the
##            membrane, a Fibonacci lattice, so the spacing follows how many
##            there are and each system holds a band of it in flow order),
##            the stores on an inner sphere (the nucleus), each toward the
##            machines it is wired to, the people at the centre;
##   torus    the flat ring given a body: the machines round the OUTER
##            circumference of a torus at their ring angles (in up to three
##            rows across the tube when there are many), the stores round
##            its INNER equator facing the hole, the people in the hole.
##
## Pure and deterministic (no RNG). Positions are in graph pixels, relative
## to the arrangement's centre (graph space, `centre`). Axes: x right, y DOWN
## the screen (graph space's own y), z toward the viewer at yaw = pitch = 0.
## The torus lies in the x-z plane, so seen from straight above
## (pitch = PI/2) it is the flat ring again, at the flat ring's angles.
##
## `layout(mode, items, conns, port_side, opts)` -> {
##     pos: {id: Vector3}, role: {id: "outer"|"inner"|"middle"},
##     centre: Vector2, extent: float (radius that holds everything),
##     shells: [{kind: "sphere", r, role} | {kind: "torus", R, a}],
##     groups: [{domain, title, ids}] (outer machines by system)}
## `project(p, yaw, pitch, dist)` -> Vector3(screen x, screen y, depth)
## in graph px, depth larger = nearer the viewer.

const SPHERE := "sphere"
const TORUS := "torus"
const MODES := [SPHERE, TORUS]
const LABELS := {
	SPHERE: "3D: nested spheres (a cell)",
	TORUS: "3D: torus",
}
## Default camera per mode (radians).
const DEFAULT_VIEW := {
	SPHERE: {"yaw": 0.55, "pitch": -0.32},
	TORUS: {"yaw": 0.25, "pitch": 1.05},
}
## Perspective: the eye stands this many extents from the centre.
const EYE_EXTENTS := 3.0
const PITCH_LIMIT := 1.5
## Rows of machines across the torus tube (angle from the outer equator).
const TORUS_ROWS := {1: [0.0], 2: [-0.55, 0.55], 3: [-0.95, 0.0, 0.95]}
const GOLDEN_ANGLE := 2.399963229728653
## Torus tube radius as a share of the outer equator's radius.
const TUBE_SHARE := 0.25
## Where the player dragged a card on its shell, per mode, on the item's
## specs: {"sphere": [x, y, z] (a direction), "torus": [theta, phi]}. A view
## preference — nothing else reads it.
const SPEC_KEY := "layout_3d"


## The item's dragged place in `mode` ({} -> none): Vector3 dir or Vector2(theta, phi).
static func override_of(item: Dictionary, mode: String) -> Variant:
	var sp: Variant = item.get("specs", {})
	if not (sp is Dictionary):
		return null
	var l3: Variant = (sp as Dictionary).get(SPEC_KEY, {})
	if not (l3 is Dictionary):
		return null
	var v: Variant = (l3 as Dictionary).get(mode)
	if not (v is Array):
		return null
	var a: Array = v
	if mode == SPHERE and a.size() >= 3:
		var d := Vector3(float(a[0]), float(a[1]), float(a[2]))
		return d.normalized() if d.length() > 1e-6 else null
	if mode == TORUS and a.size() >= 2:
		return Vector2(float(a[0]), float(a[1]))
	return null


## The value as it is stored on the specs.
static func override_to_array(v: Variant) -> Array:
	if v is Vector3:
		return [(v as Vector3).x, (v as Vector3).y, (v as Vector3).z]
	if v is Vector2:
		return [(v as Vector2).x, (v as Vector2).y]
	return []


static func layout(mode: String, items: Array, conns: Array,
		port_side: Callable = Callable(), opts: Dictionary = {}) -> Dictionary:
	if items.is_empty():
		return {"pos": {}, "role": {}, "centre": Vector2.ZERO, "extent": 0.0,
			"shells": [], "groups": []}
	var gap := float(opts.get("spacing", GraphSchemaLayout.DEFAULT_SPACING))
	var layer := GraphSchemaLayout.flow_layers(items, conns, port_side)
	var outer: Array = []
	var inner: Array = []
	var middle: Array = []
	var role := {}
	for it in items:
		var d: Dictionary = it
		var iid := str(d.get("id", ""))
		var dom := GraphSchemaLayout.domain_of(d, conns)
		if dom == GraphSchemaLayout.PEOPLE:
			middle.append(d)
			role[iid] = "middle"
		elif GraphSchemaLayout.is_store(d):
			inner.append(d)
			role[iid] = "inner"
		else:
			outer.append(d)
			role[iid] = "outer"
	var grouped := GraphSchemaLayout._grouped(outer, conns, layer)
	var ordered: Array = []
	var groups: Array = []
	for dom in GraphSchemaLayout.ORDER:
		if grouped.has(dom):
			ordered.append_array(grouped[dom])
			var ids: Array = []
			for g in (grouped[dom] as Array):
				ids.append(str((g as Dictionary).get("id", "")))
			groups.append({"domain": dom, "title": str(GraphSchemaLayout.TITLES.get(dom, dom)),
				"ids": ids})
	var res: Dictionary
	if mode == TORUS:
		res = _torus(ordered, inner, middle, conns, gap)
	else:
		res = _sphere(ordered, inner, middle, conns, gap)
	var placed_ids := {}
	for it2 in items:
		if override_of(it2 as Dictionary, mode) != null:
			placed_ids[str((it2 as Dictionary).get("id", ""))] = true
	res["placed"] = placed_ids
	res["role"] = role
	res["groups"] = groups
	res["centre"] = GraphSchemaLayout._centroid(items)
	res["mode"] = mode
	return res


# ---------------------------------------------------------------------------
# Nested spheres
# ---------------------------------------------------------------------------

static func _sphere(outer: Array, inner: Array, middle: Array, conns: Array, gap: float) -> Dictionary:
	var pos := {}
	var s_out := _mean_cell(outer, gap)
	var s_in := _mean_cell(inner, gap * 0.6)
	var mid_r := _middle_radius(middle, gap)
	# Each card takes about a cell² of surface (4 pi r² shared out).
	var r_in := maxf(sqrt(float(inner.size()) / (4.0 * PI)) * s_in * 1.45, mid_r + gap * 1.5 + 50.0)
	var max_store := _max_diag(inner)
	var max_mach := _max_diag(outer)
	var r_out := maxf(sqrt(float(outer.size()) / (4.0 * PI)) * s_out * 1.7,
		maxf(r_in * 1.7, r_in + (max_store + max_mach) * 0.5 + gap * 1.5))
	var dir := {}
	var n := outer.size()
	for i in n:
		var d: Dictionary = outer[i]
		var v := fibonacci_dir(i, n)
		var ov: Variant = override_of(d, SPHERE)
		if ov is Vector3:
			v = ov
		dir[str(d.get("id", ""))] = v
		pos[str(d.get("id", ""))] = v * r_out
	# Stores: toward the machines they are wired to, then pushed apart on
	# the inner sphere until no two cards share a spot.
	var nb := GraphSchemaLayout._neighbours(conns)
	var sd: Array = []
	var need: Array = []
	var fixed: Array = []
	for k in inner.size():
		var s: Dictionary = inner[k]
		var sid := str(s.get("id", ""))
		var v2 := Vector3.ZERO
		for o in (nb.get(sid, []) as Array):
			if dir.has(o):
				v2 += dir[o] as Vector3
		if v2.length() < 1e-4:
			v2 = fibonacci_dir(k, inner.size())
		var ov2: Variant = override_of(s, SPHERE)
		fixed.append(ov2 is Vector3)
		sd.append(ov2 if ov2 is Vector3 else v2.normalized())
		need.append((GraphSchemaLayout._size(s).length() + gap * 0.6) / r_in)
	sd = relax_on_sphere(sd, need, fixed)
	for k2 in inner.size():
		pos[str((inner[k2] as Dictionary).get("id", ""))] = (sd[k2] as Vector3) * r_in
	_place_middle(middle, gap, pos)
	return {"pos": pos, "extent": r_out + max_mach * 0.5,
		"shells": [{"kind": "sphere", "r": r_out, "role": "membrane"},
			{"kind": "sphere", "r": r_in, "role": "nucleus"}]}


## Point i of n spread evenly over the unit sphere (the Fibonacci lattice):
## y runs from the top pole (-1, up the screen) to the bottom one, each next
## point a golden angle further round, so neighbours in the list are
## neighbours on the sphere and a run of them is a band.
static func fibonacci_dir(i: int, n: int) -> Vector3:
	if n <= 1:
		return Vector3(0.0, 0.0, 1.0)
	var y := -1.0 + 2.0 * (float(i) + 0.5) / float(n)
	var r := sqrt(maxf(0.0, 1.0 - y * y))
	var th := GOLDEN_ANGLE * float(i)
	return Vector3(r * sin(th), y, r * cos(th))


## Directions on the unit sphere pushed apart until every pair is at least
## the mean of their `need` (radians) apart. Fixed number of passes, fixed
## order: deterministic.
## `fixed[i]` true: that one stays put (a card the player placed) and the
## other of a pair takes the whole push.
static func relax_on_sphere(dirs: Array, need: Array, fixed: Array = []) -> Array:
	var out: Array = dirs.duplicate()
	var m := out.size()
	if m < 2:
		return out
	var fx: Array = []
	for i in m:
		fx.append(i < fixed.size() and bool(fixed[i]))
	for _pass in 120:
		var worst := 0.0
		for a in m:
			for b in range(a + 1, m):
				var va: Vector3 = out[a]
				var vb: Vector3 = out[b]
				var ang := acos(clampf(va.dot(vb), -1.0, 1.0))
				var want := (float(need[a]) + float(need[b])) * 0.5
				var short := want - ang
				if short <= 1e-5:
					continue
				worst = maxf(worst, short)
				var axis := vb - va
				if axis.length() < 1e-6:
					# Same spot: split along a fixed direction off va.
					axis = va.cross(Vector3.UP if absf(va.y) < 0.9 else Vector3.RIGHT)
				axis = axis.normalized()
				if bool(fx[a]) and bool(fx[b]):
					continue
				var wa := 0.0 if bool(fx[a]) else (1.0 if bool(fx[b]) else 0.5)
				var wb := 1.0 - wa if not bool(fx[b]) else 0.0
				out[a] = (va - axis * short * wa).normalized()
				out[b] = (vb + axis * short * wb).normalized()
		if worst < 1e-4:
			break
	return out


# ---------------------------------------------------------------------------
# Torus
# ---------------------------------------------------------------------------

static func _torus(outer: Array, inner: Array, middle: Array, conns: Array, gap: float) -> Dictionary:
	var pos := {}
	var n := outer.size()
	var rows := 1 if n <= 18 else (2 if n <= 44 else 3)
	var phis: Array = TORUS_ROWS[rows]
	var dom_of := {}
	for d in outer:
		dom_of[str((d as Dictionary).get("id", ""))] = GraphSchemaLayout.domain_of(d, conns)
	# Arc each machine takes along the outer circumference (shared between
	# the rows), plus a gap twice as wide where one system meets the next.
	var arc := 0.0
	for i in n:
		var d1: Dictionary = outer[i]
		arc += (GraphSchemaLayout._size(d1).length() + gap) / float(rows)
		if i > 0 and dom_of[str(d1["id"])] != dom_of[str((outer[i - 1] as Dictionary)["id"])]:
			arc += gap * 2.0
	if n > 1:
		arc += gap * 2.0
	var max_mach := _max_diag(outer)
	var max_store := _max_diag(inner)
	var mid_r := _middle_radius(middle, gap)
	# R + a = the outer equator's radius; the tube a quarter of it, so the
	# hole stays open (half the ring across) and reads as a torus.
	var r_eq := maxf(arc / TAU, mid_r + max_store + max_mach + gap * 3.0)
	var a := maxf(r_eq * TUBE_SHARE, max_mach * 0.75)
	var big_r := r_eq - a
	# The inner equator (R - a) must hold the stores, and the hole the people.
	var store_arc := 0.0
	for s in inner:
		store_arc += GraphSchemaLayout._size(s).length() + gap * 0.6
	var store_rows := 1 if store_arc <= TAU * maxf(big_r - a, 1.0) * 0.9 else 2
	var inner_r_need := store_arc / float(store_rows) / TAU
	if big_r - a < inner_r_need:
		big_r = inner_r_need + a
	if big_r - a < mid_r + max_store * 0.5 + gap:
		big_r = mid_r + max_store * 0.5 + gap + a
	var theta := {}
	var r_out := big_r + a
	var t := -PI * 0.5
	for i2 in n:
		var d2: Dictionary = outer[i2]
		var w := (GraphSchemaLayout._size(d2).length() + gap) / float(rows)
		if i2 > 0 and dom_of[str(d2["id"])] != dom_of[str((outer[i2 - 1] as Dictionary)["id"])]:
			t += gap * 2.0 / r_out
		t += w * 0.5 / r_out
		var phi := float(phis[i2 % rows])
		var tt := t
		var ov: Variant = override_of(d2, TORUS)
		if ov is Vector2:
			tt = (ov as Vector2).x
			phi = (ov as Vector2).y
		theta[str(d2["id"])] = tt
		pos[str(d2["id"])] = torus_point(big_r, a, tt, phi)
		t += w * 0.5 / r_out
	# Stores on the inner equator, each at the circular mean of its machines.
	var nb := GraphSchemaLayout._neighbours(conns)
	var want: Array = []
	for k in inner.size():
		var s2: Dictionary = inner[k]
		var sid := str(s2.get("id", ""))
		var v := Vector2.ZERO
		for o in (nb.get(sid, []) as Array):
			if theta.has(o):
				v += Vector2(cos(float(theta[o])), sin(float(theta[o])))
		var th: float = v.angle() if v.length() > 1e-6 \
			else -PI * 0.5 + TAU * float(k) / float(maxi(inner.size(), 1))
		want.append([th, sid, s2])
	want.sort_custom(func(x: Array, y: Array) -> bool:
		return float(x[0]) < float(y[0]) if float(x[0]) != float(y[0]) else str(x[1]) < str(y[1]))
	var r_in := big_r - a
	var widths: Array = []
	var total := 0.0
	for e in want:
		var ww := (GraphSchemaLayout._size(e[2]).length() + gap * 0.6) / r_in / float(store_rows)
		widths.append(ww)
		total += ww
	if total > TAU:
		for q in widths.size():
			widths[q] = float(widths[q]) * TAU / total
	var placed := GraphSchemaLayout._spread_on_circle(want, widths)
	for k2 in want.size():
		var phi2 := PI if store_rows == 1 else (PI - 0.5 if k2 % 2 == 0 else PI + 0.5)
		var ov3: Variant = override_of(want[k2][2] as Dictionary, TORUS)
		if ov3 is Vector2:
			pos[str(want[k2][1])] = torus_point(big_r, a, (ov3 as Vector2).x, (ov3 as Vector2).y)
			continue
		pos[str(want[k2][1])] = torus_point(big_r, a, float(placed[k2]), phi2)
	_place_middle(middle, gap, pos)
	return {"pos": pos, "extent": r_out + max_mach * 0.5,
		"shells": [{"kind": "torus", "R": big_r, "a": a}]}


## A point on a torus of major radius `big_r` and tube radius `a` lying in
## the x-z plane: `theta` round the ring as the flat ring measures it (seen
## from above, screen angle), `phi` round the tube (0 = outer equator,
## PI = inner equator, + = down the screen).
static func torus_point(big_r: float, a: float, theta: float, phi: float) -> Vector3:
	var rr := big_r + a * cos(phi)
	return Vector3(rr * cos(theta), a * sin(phi), -rr * sin(theta))


# ---------------------------------------------------------------------------
# Shared
# ---------------------------------------------------------------------------

static func _place_middle(middle: Array, gap: float, pos: Dictionary) -> void:
	var m := middle.size()
	if m == 1:
		pos[str((middle[0] as Dictionary).get("id", ""))] = Vector3.ZERO
		return
	var r := _middle_radius(middle, gap) * 0.6
	for i in m:
		var a := TAU * float(i) / float(m)
		pos[str((middle[i] as Dictionary).get("id", ""))] = Vector3(cos(a) * r, 0.0, sin(a) * r)


static func _middle_radius(middle: Array, gap: float) -> float:
	if middle.is_empty():
		return 0.0
	var r := 0.0
	for m in middle:
		r = maxf(r, GraphSchemaLayout._size(m).length() * 0.5)
	if middle.size() > 1:
		r += (r + gap) * float(middle.size()) / TAU
	return r


static func _mean_cell(arr: Array, gap: float) -> float:
	if arr.is_empty():
		return 120.0 + gap
	var s := 0.0
	for it in arr:
		s += GraphSchemaLayout._size(it).length()
	return s / float(arr.size()) + gap


static func _max_diag(arr: Array) -> float:
	var m := 0.0
	for it in arr:
		m = maxf(m, GraphSchemaLayout._size(it).length())
	return m


## Turn by `yaw` about the vertical (screen y) axis, then tilt by `pitch`
## about the horizontal one.
static func rotate(p: Vector3, yaw: float, pitch: float) -> Vector3:
	var cy := cos(yaw)
	var sy := sin(yaw)
	var x := p.x * cy + p.z * sy
	var z := -p.x * sy + p.z * cy
	var cp := cos(pitch)
	var sp := sin(pitch)
	return Vector3(x, p.y * cp - z * sp, p.y * sp + z * cp)


## The inverse of `rotate`.
static func unrotate(p: Vector3, yaw: float, pitch: float) -> Vector3:
	var cp := cos(pitch)
	var sp := sin(pitch)
	var y := p.y * cp + p.z * sp
	var z := -p.y * sp + p.z * cp
	var cy := cos(yaw)
	var sy := sin(yaw)
	return Vector3(p.x * cy - z * sy, y, p.x * sy + z * cy)


## Perspective scale for a point at view depth `z` (toward the eye +) with
## the eye `dist` from the centre.
static func persp(z: float, dist: float) -> float:
	return dist / maxf(dist - z, dist * 0.2)


static func project(p: Vector3, yaw: float, pitch: float, dist: float) -> Vector3:
	var r := rotate(p, yaw, pitch)
	var f := persp(r.z, dist)
	return Vector3(r.x * f, r.y * f, r.z)


## Torus: a curve from a to b through the inside of the tube — it bows
## toward the tube's core circle (radius `big_r`) at the angle between its
## ends, so the wires run round inside the torus and the hole stays clear.
## Ends on opposite sides fall back to a curve through the hole.
static func connector_points_torus(a: Vector3, b: Vector3, big_r: float, pull: float = 0.8,
		n: int = 16) -> PackedVector3Array:
	var mid := (a + b) * 0.5
	var flat := Vector2(mid.x, -mid.z)
	if flat.length() < big_r * 0.2:
		return connector_points(a, b, 0.35, n)
	var th := flat.angle()
	var core := torus_point(big_r, 0.0, th, 0.0)
	var c := mid.lerp(core, pull)
	var out := PackedVector3Array()
	out.resize(n + 1)
	for i in n + 1:
		var t := float(i) / float(n)
		var u := 1.0 - t
		out[i] = a * (u * u) + c * (2.0 * u * t) + b * (t * t)
	return out


## A curve from a to b that bows toward the centre (the wires run INSIDE
## the sphere / through the torus's hole): a quadratic bezier whose control
## point is the midpoint pulled `pull` of the way in.
static func connector_points(a: Vector3, b: Vector3, pull: float = 0.55, n: int = 16) -> PackedVector3Array:
	var c := (a + b) * 0.5 * (1.0 - pull)
	var out := PackedVector3Array()
	out.resize(n + 1)
	for i in n + 1:
		var t := float(i) / float(n)
		var u := 1.0 - t
		out[i] = a * (u * u) + c * (2.0 * u * t) + b * (t * t)
	return out
