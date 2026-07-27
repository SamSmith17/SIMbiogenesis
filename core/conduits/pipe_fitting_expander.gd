class_name PipeFittingExpander
extends RefCounted

## Sparse 3D control points → sharp polyline with only 0° / 45° / 90° turns
## so PipePartsPlanner can seat kit elbows. Preserves pin Y via risers +
## horizontal 45° lattice runs (compound S/U across multiple pins).

const EPS_M := 0.02
const COLINEAR_DEG := 2.0
const DEFAULT_STEP_DEG := 45.0


## Expand [A, p1…pn, B] into a kit-legal sharp polyline.
static func expand(control: Array, fitting_step_deg: float = DEFAULT_STEP_DEG) -> PackedVector3Array:
	var pts := _to_packed(control)
	if pts.size() < 2:
		return pts
	var step := fitting_step_deg if fitting_step_deg > 0.5 else DEFAULT_STEP_DEG
	var out := PackedVector3Array()
	out.append(pts[0])
	for i: int in range(pts.size() - 1):
		var span := expand_span(pts[i], pts[i + 1], step)
		for j: int in range(1, span.size()):
			_append_dedupe(out, span[j])
	out = legalize_corners(out, step)
	# Lattice doglegs often emit two coplanar 45° corners that are one 90° elbow.
	out = collapse_double_45(out)
	return out


## Replace coplanar 45°+45° pairs with a single 90° corner when the net turn is ~90°.
## Fixes short “zigzag” fittings that should be one long-sweep / standard 90°.
static func collapse_double_45(pts: PackedVector3Array) -> PackedVector3Array:
	if pts.size() < 4:
		return pts
	var cur := pts
	var guard := 0
	while guard < 12:
		guard += 1
		var next := PackedVector3Array()
		next.append(cur[0])
		var i := 1
		var changed := false
		while i < cur.size() - 1:
			if i + 2 >= cur.size():
				next.append(cur[i])
				i += 1
				continue
			var p0 := cur[i - 1]
			var p1 := cur[i]
			var p2 := cur[i + 1]
			var p3 := cur[i + 2]
			var d0 := p1 - p0
			var d1 := p2 - p1
			var d2 := p3 - p2
			if d0.length_squared() < 1e-12 or d1.length_squared() < 1e-12 \
					or d2.length_squared() < 1e-12:
				next.append(p1)
				i += 1
				continue
			var n0 := d0.normalized()
			var n1 := d1.normalized()
			var n2 := d2.normalized()
			var t1 := rad_to_deg(n0.angle_to(n1))
			var t2 := rad_to_deg(n1.angle_to(n2))
			var total := rad_to_deg(n0.angle_to(n2))
			var pair_45 := absf(t1 - 45.0) <= 12.0 and absf(t2 - 45.0) <= 12.0
			var net_90 := absf(total - 90.0) <= 14.0
			var c0 := n0.cross(n1)
			var c1 := n1.cross(n2)
			var coplanar := c0.length_squared() < 1e-8 or c1.length_squared() < 1e-8 \
					or absf(c0.normalized().dot(c1.normalized())) > 0.92
			var same_sense := c0.length_squared() < 1e-8 or c1.length_squared() < 1e-8 \
					or c0.dot(c1) > 0.0
			# Short diagonal between the two 45s — always try collapse when net ~90°.
			var short_mid := d1.length() < 0.35
			if pair_45 and net_90 and coplanar and same_sense \
					and (short_mid or d1.length() < 2.5):
				var corner := _rays_meet(p0, n0, p3, -n2)
				if corner != Vector3.INF \
						and corner.distance_to(p0) > EPS_M \
						and corner.distance_to(p3) > EPS_M:
					_append_dedupe(next, corner)
					i += 2  # skip p1,p2; p3 appended on next iteration / end
					changed = true
					continue
			next.append(p1)
			i += 1
		_append_dedupe(next, cur[cur.size() - 1])
		cur = next
		if not changed:
			break
	return cur


## Closest-point meeting of ray p0+t·d0 and p1+s·d1 (t,s ≥ 0 preferred).
static func _rays_meet(p0: Vector3, d0: Vector3, p1: Vector3, d1: Vector3) -> Vector3:
	var a := d0.normalized()
	var b := d1.normalized()
	var w0 := p0 - p1
	var aa := a.dot(a)
	var bb := b.dot(b)
	var ab := a.dot(b)
	var aw := a.dot(w0)
	var bw := b.dot(w0)
	var den := aa * bb - ab * ab
	if absf(den) < 1e-10:
		return Vector3.INF
	var t := (ab * bw - bb * aw) / den
	var s := (aa * bw - ab * aw) / den
	# Allow a little back-projection for numeric noise, not a wild miss.
	if t < -0.05 or s < -0.05:
		return Vector3.INF
	var q0 := p0 + a * t
	var q1 := p1 + b * s
	if q0.distance_to(q1) > 0.08:
		return Vector3.INF
	return (q0 + q1) * 0.5


## One span P→Q with risers + horizontal fitting doglegs (true 3D).
static func expand_span(a: Vector3, b: Vector3,
		fitting_step_deg: float = DEFAULT_STEP_DEG) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.append(a)
	var delta := b - a
	if delta.length() < 1e-4:
		_append_dedupe(out, b)
		return out
	var dx := delta.x
	var dy := delta.y
	var dz := delta.z
	# Pure vertical riser — 90° at the endpoints of a longer run, not here.
	if absf(dx) < 1e-4 and absf(dz) < 1e-4:
		_append_dedupe(out, b)
		return out
	# Pure horizontal.
	if absf(dy) < EPS_M:
		_append_horizontal(out, a, b, fitting_step_deg)
		return out
	# Prefer leave at A's height, run, then rise/drop to B (wall-pin friendly).
	var leave := _path_leave_then_rise(a, b, fitting_step_deg)
	if _turns_are_legal(leave):
		return leave
	var rise := _path_rise_then_run(a, b, fitting_step_deg)
	if _turns_are_legal(rise):
		return rise
	# Fallback: axis-aligned 3D Manhattan (90° only).
	return _path_axis_3d(a, b)


## Map turn angle → 45 or 90 via morph midpoint (for UX / selftests).
static func morph_bend_deg(turn_deg: float) -> float:
	return PipePartsPlanner.morph_bend_deg(turn_deg)


## Insert compound corners wherever a stitch left an illegal turn.
static func legalize_corners(pts: PackedVector3Array,
		fitting_step_deg: float = DEFAULT_STEP_DEG) -> PackedVector3Array:
	if pts.size() < 3:
		return pts
	var guard := 0
	var cur := pts
	while guard < 8:
		guard += 1
		var bad_i := _first_illegal_corner(cur)
		if bad_i < 0:
			return cur
		# Replace neighborhood A–C–B with expand_span(A,B) which invents legal S/U
		# that still roughly covers C by routing through C as a waypoint pair.
		var a := cur[bad_i - 1]
		var c := cur[bad_i]
		var b := cur[bad_i + 1]
		var rebuilt := PackedVector3Array()
		for i: int in range(bad_i):
			rebuilt.append(cur[i])
		# Compound: A→C then C→B (each span legal); stitch at C.
		var s1 := expand_span(a, c, fitting_step_deg)
		var s2 := expand_span(c, b, fitting_step_deg)
		for j: int in range(1, s1.size()):
			_append_dedupe(rebuilt, s1[j])
		for j: int in range(1, s2.size()):
			_append_dedupe(rebuilt, s2[j])
		for i: int in range(bad_i + 2, cur.size()):
			_append_dedupe(rebuilt, cur[i])
		# If still illegal at same index, force axis U around C.
		if _first_illegal_corner(rebuilt) == bad_i \
				or (rebuilt.size() == cur.size() and _corners_equal(rebuilt, cur)):
			rebuilt = PackedVector3Array()
			for i: int in range(bad_i):
				rebuilt.append(cur[i])
			var u := _compound_u_through(a, c, b, fitting_step_deg)
			for j: int in range(1, u.size()):
				_append_dedupe(rebuilt, u[j])
			for i: int in range(bad_i + 2, cur.size()):
				_append_dedupe(rebuilt, cur[i])
		cur = rebuilt
	return cur


static func _path_leave_then_rise(a: Vector3, b: Vector3, step: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.append(a)
	var horiz_end := Vector3(b.x, a.y, b.z)
	if a.distance_to(horiz_end) > EPS_M:
		_append_horizontal(out, a, horiz_end, step)
	if absf(b.y - a.y) > EPS_M:
		_append_dedupe(out, b)
	elif out[out.size() - 1].distance_to(b) > EPS_M:
		_append_dedupe(out, b)
	return out


static func _path_rise_then_run(a: Vector3, b: Vector3, step: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.append(a)
	var risen := Vector3(a.x, b.y, a.z)
	if absf(b.y - a.y) > EPS_M:
		_append_dedupe(out, risen)
	if risen.distance_to(b) > EPS_M:
		_append_horizontal(out, risen, b, step)
	elif out[out.size() - 1].distance_to(b) > EPS_M:
		_append_dedupe(out, b)
	return out


static func _path_axis_3d(a: Vector3, b: Vector3) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.append(a)
	var cur := a
	var dx := b.x - a.x
	var dy := b.y - a.y
	var dz := b.z - a.z
	# Longer horizontal first, then the other, then Y — classic pipes.
	if absf(dx) >= absf(dz):
		if absf(dx) > 1e-4:
			cur = Vector3(b.x, cur.y, cur.z)
			out.append(cur)
		if absf(dz) > 1e-4:
			cur = Vector3(cur.x, cur.y, b.z)
			out.append(cur)
	else:
		if absf(dz) > 1e-4:
			cur = Vector3(cur.x, cur.y, b.z)
			out.append(cur)
		if absf(dx) > 1e-4:
			cur = Vector3(b.x, cur.y, cur.z)
			out.append(cur)
	if absf(dy) > 1e-4:
		out.append(b)
	elif out[out.size() - 1].distance_to(b) > EPS_M:
		out.append(b)
	return out


## 90+90 (or 45 lattice) U that passes through waypoint C between A and B.
static func _compound_u_through(a: Vector3, c: Vector3, b: Vector3,
		step: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.append(a)
	# Approach C at a.y, through C, then to b — using leave/rise per leg.
	var s1 := _path_leave_then_rise(a, c, step)
	for j: int in range(1, s1.size()):
		_append_dedupe(out, s1[j])
	var s2 := _path_leave_then_rise(c, b, step)
	for j: int in range(1, s2.size()):
		_append_dedupe(out, s2[j])
	if not _turns_are_legal(out):
		out = PackedVector3Array()
		out.append(a)
		var m1 := _path_axis_3d(a, c)
		for j: int in range(1, m1.size()):
			_append_dedupe(out, m1[j])
		var m2 := _path_axis_3d(c, b)
		for j: int in range(1, m2.size()):
			_append_dedupe(out, m2[j])
	return out


static func _append_horizontal(out: PackedVector3Array, a: Vector3, b: Vector3,
		step: float) -> void:
	var span: Array = ConduitPipesRouter._fitting_span(a, b, step)
	for i: int in range(1, span.size()):
		_append_dedupe(out, span[i] as Vector3)


static func _turns_are_legal(pts: PackedVector3Array) -> bool:
	return _first_illegal_corner(pts) < 0


static func _first_illegal_corner(pts: PackedVector3Array) -> int:
	for i: int in range(1, pts.size() - 1):
		var d_in := pts[i] - pts[i - 1]
		var d_out := pts[i + 1] - pts[i]
		if d_in.length_squared() < 1e-12 or d_out.length_squared() < 1e-12:
			return i
		var turn := rad_to_deg(d_in.normalized().angle_to(d_out.normalized()))
		if turn < COLINEAR_DEG:
			continue
		# Legal if morph lands on 45 or 90 (kit elbows).
		var m := PipePartsPlanner.morph_bend_deg(turn)
		if m < 0.5:
			continue
		if absf(turn - m) <= 12.0:
			continue
		# Also accept exact classify band.
		if absf(turn - 45.0) <= 12.0 or absf(turn - 90.0) <= 12.0:
			continue
		return i
	return -1


static func _append_dedupe(out: PackedVector3Array, p: Vector3) -> void:
	if out.is_empty() or out[out.size() - 1].distance_to(p) > EPS_M * 0.5:
		out.append(p)


static func _to_packed(control: Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	for v: Variant in control:
		if v is Vector3:
			_append_dedupe(out, v as Vector3)
		elif v is Dictionary:
			var d: Dictionary = v
			_append_dedupe(out, Vector3(
				float(d.get("x", 0.0)), float(d.get("y", 0.0)), float(d.get("z", 0.0))))
	return out


static func _corners_equal(a: PackedVector3Array, b: PackedVector3Array) -> bool:
	if a.size() != b.size():
		return false
	for i: int in range(a.size()):
		if a[i].distance_to(b[i]) > 1e-4:
			return false
	return true
