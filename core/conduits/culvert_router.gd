class_name CulvertRouter
extends RefCounted

## Large-radius PE culvert routing. Sparse control points → centerline with
## circular fillets (min bend radius ≈ 3–5× OD). No discrete 45/90 elbows —
## corrugation rings flex in wide arcs the way dual-wall HDPE actually bends.

const EPS_M := 0.02
const COLINEAR_DEG := 3.0
const ARC_STEP_DEG := 6.0


## Expand ports/pins into a PE-legal centerline (arc-filleted polyline).
static func expand(control: Array, bend_radius_m: float) -> PackedVector3Array:
	var pts := _dedupe(_to_packed(control))
	if pts.size() < 2:
		return pts
	var r := maxf(bend_radius_m, 0.15)
	# Prefer leave-at-height then rise (wall-pin friendly), else axis path.
	var spine := _build_spine(pts)
	spine = _dedupe(spine)
	if spine.size() < 2:
		return pts
	return fillet_polyline(spine, r)


## Insert circular fillets at every non-colinear corner.
static func fillet_polyline(pts: PackedVector3Array, bend_radius_m: float) -> PackedVector3Array:
	if pts.size() < 3:
		return pts
	var r := maxf(bend_radius_m, 0.05)
	var out := PackedVector3Array()
	out.append(pts[0])
	for i: int in range(1, pts.size() - 1):
		var a := pts[i - 1]
		var b := pts[i]
		var c := pts[i + 1]
		var d_in := b - a
		var d_out := c - b
		if d_in.length_squared() < 1e-10 or d_out.length_squared() < 1e-10:
			_append(out, b)
			continue
		var n_in := d_in.normalized()
		var n_out := d_out.normalized()
		var turn := rad_to_deg(n_in.angle_to(n_out))
		if turn < COLINEAR_DEG:
			continue
		var fil := _fillet_corner(a, b, c, r)
		if fil.is_empty():
			_append(out, b)
			continue
		for p: Vector3 in fil:
			_append(out, p)
	_append(out, pts[pts.size() - 1])
	return out


## Circular fillet samples from near A→B into B→C (excludes A, may exclude C).
static func _fillet_corner(a: Vector3, b: Vector3, c: Vector3,
		r: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	var d_in := b - a
	var d_out := c - b
	var len_in := d_in.length()
	var len_out := d_out.length()
	if len_in < EPS_M or len_out < EPS_M:
		return out
	var n_in := d_in / len_in
	var n_out := d_out / len_out
	var cos_t := clampf(n_in.dot(n_out), -1.0, 1.0)
	var turn := acos(cos_t)
	if turn < deg_to_rad(COLINEAR_DEG):
		return out
	# Tangent length for fillet of radius r through angle turn.
	var t_len := r * tan(turn * 0.5)
	# Shrink radius if legs are too short for a full fillet.
	var max_t := minf(len_in, len_out) * 0.48
	if t_len > max_t:
		t_len = max_t
		r = t_len / maxf(tan(turn * 0.5), 1e-4)
	if r < 0.05 or t_len < 0.03:
		return out
	var p0 := b - n_in * t_len
	var p1 := b + n_out * t_len
	# Fillet plane / center: offset from corner along angle bisector of the
	# supplement (inside of bend).
	var cross := n_in.cross(n_out)
	if cross.length_squared() < 1e-12:
		return out
	var axis := cross.normalized()
	# Inward normal (bisector pointing into the bend).
	var bis := (-n_in + n_out)
	if bis.length_squared() < 1e-12:
		bis = axis.cross(n_in)
	bis = bis.normalized()
	# Distance from chord midpoint to center = r / sin(turn/2) along bis? 
	# Center = p0 + rot90(n_in) * r (side matching axis).
	var side := axis.cross(n_in).normalized()
	# Choose side so center is on the inside of the turn.
	if side.dot(bis) < 0.0:
		side = -side
	var center := p0 + side * r
	# Verify p1 is also ~r from center; if not, fall back to lerp arc.
	if absf(center.distance_to(p1) - r) > r * 0.25 + 0.05:
		return _lerp_arc(p0, b, p1, turn)
	var v0 := (p0 - center).normalized()
	var v1 := (p1 - center).normalized()
	# Signed angle about axis from v0 to v1.
	var ang := atan2(axis.dot(v0.cross(v1)), v0.dot(v1))
	if absf(ang) < deg_to_rad(2.0):
		_append(out, p0)
		_append(out, p1)
		return out
	var steps := clampi(int(ceil(absf(rad_to_deg(ang)) / ARC_STEP_DEG)), 3, 36)
	for s: int in range(steps + 1):
		var u := float(s) / float(steps)
		var q := Quaternion(axis, ang * u)
		out.append(center + q * v0 * r)
	return out


static func _lerp_arc(p0: Vector3, b: Vector3, p1: Vector3, turn: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	var steps := clampi(int(ceil(rad_to_deg(turn) / ARC_STEP_DEG)), 3, 24)
	for s: int in range(steps + 1):
		var u := float(s) / float(steps)
		# Quadratic Bezier through the corner — wide soft bend fallback.
		var q := (1.0 - u) * (1.0 - u) * p0 + 2.0 * (1.0 - u) * u * b + u * u * p1
		out.append(q)
	return out


## Spine through controls: keep mid pins; only invent a leave/rise L when the
## chain is a bare A→B span (otherwise mid corners are lost and fillets vanish).
static func _build_spine(pts: PackedVector3Array) -> PackedVector3Array:
	if pts.size() == 2:
		return _axis_soft(pts[0], pts[1])
	return pts


## Graded PE centerline A→B (lerp XZ + Y) for downhill/uphill barrels.
## Prefer a real barrel slope over leave-horizontal-then-drop L (deep U look).
static func _axis_soft(a: Vector3, b: Vector3) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.append(a)
	var dx := b.x - a.x
	var dy := b.y - a.y
	var dz := b.z - a.z
	if absf(dx) < 1e-4 and absf(dz) < 1e-4:
		if a.distance_to(b) > EPS_M:
			out.append(b)
		return out
	var horiz_len := sqrt(dx * dx + dz * dz)
	# Short / steep runs: single graded segment (no invented mid elbow).
	if horiz_len < 80.0 or absf(dy) / maxf(horiz_len, 0.1) > 0.08:
		if a.distance_to(b) > EPS_M:
			out.append(b)
		return out
	# Long shallow runs: one mid pin on the grade line (fillets stay mild).
	var mid := a.lerp(b, 0.5)
	out.append(mid)
	if mid.distance_to(b) > EPS_M:
		out.append(b)
	return out


static func _to_packed(control: Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	for v: Variant in control:
		if v is Vector3:
			out.append(v as Vector3)
	return out


static func _dedupe(pts: PackedVector3Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	for p: Vector3 in pts:
		if out.is_empty() or out[out.size() - 1].distance_to(p) > EPS_M * 0.5:
			out.append(p)
	return out


static func _append(out: PackedVector3Array, p: Vector3) -> void:
	if out.is_empty() or out[out.size() - 1].distance_to(p) > EPS_M * 0.35:
		out.append(p)
