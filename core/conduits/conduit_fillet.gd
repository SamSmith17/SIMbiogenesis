class_name ConduitFillet
extends RefCounted

## Real bends. Each interior corner of a run becomes a circular arc TANGENT to
## both legs at the pipe's minimum bend radius: the arc starts and ends
## t = r · tan(φ / 2) back from the corner along each leg (φ = the turn), and
## its centre lies on the corner's bisector. The old softening drew an arc
## centred ON the corner, a share of the shorter leg in size, and the kit
## legaliser then chopped that into doglegs. Pure static.

## Arc samples every this many degrees of turn.
const STEP_DEG := 7.5
## Turns smaller than this are left sharp (a nearly straight run).
const MIN_TURN_DEG := 1.0


## `corners` sharp polyline -> {points: PackedVector3Array, tight: Array of
## corner indices whose radius had to shrink, radii: PackedFloat32Array}.
## Two arcs sharing a leg split it in proportion; an end leg (port to stub end)
## belongs to its one corner. The solver makes stubs long enough that a
## full-radius bend stays clear of the port's fitting.
## `per_corner` (optional, one per corner): a corner's own radius where > 0
## (the bundler's concentric bends), else `radius`.
static func apply(corners: PackedVector3Array, radius: float,
		step_deg: float = STEP_DEG, per_corner: PackedFloat64Array = PackedFloat64Array()) -> Dictionary:
	var n := corners.size()
	var out := {"points": corners, "tight": [], "radii": PackedFloat32Array()}
	if n < 3 or radius <= 0.0:
		return out
	# Tangent lengths each corner wants, then shrink pairs that overlap a leg.
	var want := PackedFloat64Array()
	var turn := PackedFloat64Array()
	want.resize(n)
	turn.resize(n)
	for i: int in range(1, n - 1):
		var d0 := corners[i] - corners[i - 1]
		var d1 := corners[i + 1] - corners[i]
		if d0.length_squared() < 1e-12 or d1.length_squared() < 1e-12:
			continue
		var phi := d0.normalized().angle_to(d1.normalized())
		if rad_to_deg(phi) < MIN_TURN_DEG or rad_to_deg(phi) > 179.0:
			continue
		turn[i] = phi
		want[i] = _r_at(i, radius, per_corner) * tan(phi * 0.5)
	var tight: Array = []
	var t_use := want.duplicate()
	for i: int in range(n - 1):
		var leg := corners[i].distance_to(corners[i + 1])
		var a := t_use[i] if i > 0 else 0.0
		var b := t_use[i + 1] if i + 1 < n - 1 else 0.0
		if a + b > leg - 1e-6:
			var k := (leg - 1e-6) / maxf(a + b, 1e-9)
			if i > 0:
				t_use[i] = a * k
			if i + 1 < n - 1:
				t_use[i + 1] = b * k
	var pts := PackedVector3Array()
	var radii := PackedFloat32Array()
	pts.append(corners[0])
	for i: int in range(1, n - 1):
		var c := corners[i]
		if turn[i] <= 0.0 or t_use[i] < 1e-5:
			pts.append(c)
			radii.append(0.0)
			continue
		var phi := turn[i]
		var t := t_use[i]
		var r := t / tan(phi * 0.5)
		if r < _r_at(i, radius, per_corner) * 0.999:
			tight.append(i)
		radii.append(r)
		var d0 := (c - corners[i - 1]).normalized()
		var d1 := (corners[i + 1] - c).normalized()
		var p_start := c - d0 * t
		var bis := (d1 - d0).normalized()
		var centre := c + bis * (r / cos(phi * 0.5))
		var axis := d0.cross(d1)
		if axis.length_squared() < 1e-12:
			pts.append(c)
			continue
		axis = axis.normalized()
		var steps := maxi(2, int(ceil(rad_to_deg(phi) / maxf(step_deg, 1.0))))
		var v0 := p_start - centre
		for s: int in range(steps + 1):
			var ang := phi * float(s) / float(steps)
			pts.append(centre + v0.rotated(axis, ang))
	pts.append(corners[n - 1])
	out["points"] = _dedupe(pts)
	out["tight"] = tight
	out["radii"] = radii
	return out


## Where the arcs start and end, for fittings and the bend editor: one entry
## per interior corner {corner, start, end, radius, turn_deg}.
static func bends(corners: PackedVector3Array, radius: float) -> Array:
	var res := apply(corners, radius)
	var radii: PackedFloat32Array = res["radii"]
	var out: Array = []
	for i: int in range(1, corners.size() - 1):
		var r := float(radii[i - 1]) if i - 1 < radii.size() else 0.0
		if r <= 0.0:
			continue
		var d0 := (corners[i] - corners[i - 1]).normalized()
		var d1 := (corners[i + 1] - corners[i]).normalized()
		var phi := d0.angle_to(d1)
		var t := r * tan(phi * 0.5)
		out.append({"corner": corners[i], "start": corners[i] - d0 * t,
			"end": corners[i] + d1 * t, "radius": r, "turn_deg": rad_to_deg(phi)})
	return out


static func _r_at(i: int, radius: float, per_corner: PackedFloat64Array) -> float:
	if i < per_corner.size() and per_corner[i] > 0.0:
		return per_corner[i]
	return radius


static func _dedupe(pts: PackedVector3Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	for p: Vector3 in pts:
		if out.is_empty() or out[out.size() - 1].distance_to(p) > 1e-5:
			out.append(p)
	return out
