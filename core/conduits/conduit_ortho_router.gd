class_name ConduitOrthoRouter
extends RefCounted

## Build axis-aligned + 45° polylines between endpoints for rigid conduits
## (PVC / duct / Romex). Optional elbow arc samples soften sharp corners.

const ELBOW_SAMPLES := 4
const ELBOW_RADIUS_FRAC := 0.35  ## fraction of min adjacent segment used as bend radius
const MIN_ELBOW_M := 0.05


## Route from A to B with optional intermediate waypoints. Prefer horizontal
## plane first (X then Z), then vertical. When allow_45 is true, a single
## diagonal mid-step is used when the XZ delta is roughly square.
## `elbow_radius_frac` 0 = sharp corners; default softens elbows.
static func route(a: Vector3, b: Vector3, waypoints: Array = [],
		allow_45: bool = true, elbow_radius_frac: float = ELBOW_RADIUS_FRAC) -> PackedVector3Array:
	var corners: Array = [a]
	for wp: Variant in waypoints:
		if wp is Vector3:
			corners.append(wp)
		elif wp is Dictionary:
			corners.append(Vector3(
				float(wp.get("x", 0.0)),
				float(wp.get("y", 0.0)),
				float(wp.get("z", 0.0))))
	corners.append(b)
	var ortho: Array = []
	ortho.append(corners[0])
	for i: int in range(corners.size() - 1):
		var from: Vector3 = corners[i] as Vector3
		var to: Vector3 = corners[i + 1] as Vector3
		var mid := _ortho_span(from, to, allow_45)
		for j: int in range(1, mid.size()):
			ortho.append(mid[j])
	var packed := PackedVector3Array(ortho)
	if elbow_radius_frac <= 0.001:
		return packed
	return soften_elbows(packed, ELBOW_SAMPLES, elbow_radius_frac)


static func _ortho_span(a: Vector3, b: Vector3, allow_45: bool) -> Array:
	var out: Array = [a]
	if a.distance_to(b) < 1e-4:
		out.append(b)
		return out
	var dx := b.x - a.x
	var dy := b.y - a.y
	var dz := b.z - a.z
	# Keep Y for last step so pipes rise/drop at the destination.
	var ax := absf(dx)
	var az := absf(dz)
	if allow_45 and ax > 0.05 and az > 0.05:
		var diag := minf(ax, az)
		var sx := signf(dx)
		var sz := signf(dz)
		var p1 := Vector3(a.x + sx * diag, a.y, a.z + sz * diag)
		if p1.distance_to(a) > 1e-4:
			out.append(p1)
		var p2 := Vector3(b.x, a.y, b.z)
		if p2.distance_to(p1) > 1e-4:
			out.append(p2)
	else:
		if absf(dx) > 1e-4:
			out.append(Vector3(b.x, a.y, a.z))
		if absf(dz) > 1e-4:
			var last: Vector3 = out[out.size() - 1] as Vector3
			out.append(Vector3(b.x, a.y, b.z))
			if (out[out.size() - 1] as Vector3).distance_to(last) < 1e-4:
				out.pop_back()
	var last2: Vector3 = out[out.size() - 1] as Vector3
	if absf(dy) > 1e-4 or last2.distance_to(b) > 1e-4:
		out.append(b)
	return out


## Replace sharp corners with short circular arc samples in the corner plane.
## `elbow_radius_frac` = fraction of the shorter adjacent leg used as bend radius.
static func soften_elbows(points: PackedVector3Array,
		samples: int = ELBOW_SAMPLES,
		elbow_radius_frac: float = ELBOW_RADIUS_FRAC) -> PackedVector3Array:
	var out := PackedVector3Array()
	if points.size() < 3:
		return points
	if elbow_radius_frac <= 0.001:
		return points
	out.append(points[0])
	for i: int in range(1, points.size() - 1):
		var prev: Vector3 = points[i - 1]
		var cur: Vector3 = points[i]
		var next: Vector3 = points[i + 1]
		var v0 := prev - cur
		var v1 := next - cur
		var l0 := v0.length()
		var l1 := v1.length()
		if l0 < 1e-4 or l1 < 1e-4:
			out.append(cur)
			continue
		var d0 := v0 / l0
		var d1 := v1 / l1
		var cos_a := clampf(d0.dot(d1), -1.0, 1.0)
		# Nearly colinear — keep the vertex.
		if cos_a < -0.98:
			out.append(cur)
			continue
		var frac := clampf(elbow_radius_frac, 0.0, 0.45)
		var radius := minf(l0, l1) * frac
		if frac > 0.001:
			radius = maxf(radius, MIN_ELBOW_M)
		radius = minf(radius, minf(l0, l1) * 0.45)
		var start := cur + d0 * radius
		var end := cur + d1 * radius
		out.append(start)
		# Circular fillet: the arc sweeps the offset direction from d0 (the leg
		# toward `start`) to d1 (the leg toward `end`), so points trace an arc of
		# radius `radius` centred on the corner from start to end. The old code
		# rotated -d0 by the EXTERIOR angle around d0×d1, which started the arc on
		# the opposite side of the corner and spun it the wrong way — a spike/kink
		# at every bend, then a snap to `end`. Rotate d0 toward d1 by the interior
		# angle instead.
		var n := d0.cross(d1)
		if n.length_squared() < 1e-8:
			out.append(cur)
			out.append(end)
			continue
		n = n.normalized()
		var arc_angle := acos(clampf(d0.dot(d1), -1.0, 1.0))
		var segs := maxi(samples, 2)
		for s: int in range(1, segs):
			var t := float(s) / float(segs)
			var dir := d0.rotated(n, arc_angle * t)
			out.append(cur + dir * radius)
		out.append(end)
	out.append(points[points.size() - 1])
	return out


## Ground-following “metro” route: drop to ground near A, ortho+45 through mids
## with rounded elbows, rise to B. No catenary. `ground_y_fn(Vector3)->float`.
static func metro_ground_route(a: Vector3, b: Vector3, waypoints: Array,
		ground_y_fn: Callable, clearance_m: float = 0.05) -> PackedVector3Array:
	var out := PackedVector3Array()
	if not ground_y_fn.is_valid():
		return route(a, b, waypoints, true)
	var ga := Vector3(a.x, float(ground_y_fn.call(a)) + clearance_m, a.z)
	var gb := Vector3(b.x, float(ground_y_fn.call(b)) + clearance_m, b.z)
	var mids: Array = []
	for wp: Variant in waypoints:
		var p: Vector3
		if wp is Vector3:
			p = wp as Vector3
		elif wp is Dictionary:
			p = Vector3(float(wp.get("x", 0.0)), float(wp.get("y", 0.0)),
				float(wp.get("z", 0.0)))
		else:
			continue
		mids.append(Vector3(p.x, float(ground_y_fn.call(p)) + clearance_m, p.z))
	# Flat run plane (mean of endpoint clearances) — no per-sample DEM re-drape
	# (that turned soft elbows into jagged terrain spaghetti).
	var y_run := (ga.y + gb.y) * 0.5
	ga.y = y_run
	gb.y = y_run
	for i: int in mids.size():
		var mp: Vector3 = mids[i] as Vector3
		mids[i] = Vector3(mp.x, y_run, mp.z)
	var packed := route(ga, gb, mids, true)
	if a.distance_to(Vector3(a.x, float(ground_y_fn.call(a)) + clearance_m, a.z)) > 0.08:
		out.append(a)
		out.append(Vector3(a.x, float(ground_y_fn.call(a)) + clearance_m, a.z))
	for p: Vector3 in packed:
		out.append(Vector3(p.x, y_run, p.z))
	var gb_ground := Vector3(b.x, float(ground_y_fn.call(b)) + clearance_m, b.z)
	if b.distance_to(gb_ground) > 0.08:
		out.append(gb_ground)
		out.append(b)
	elif out.is_empty() or out[out.size() - 1].distance_to(b) > 0.02:
		out.append(b)
	return out


## True when consecutive segments are only axis-aligned or 45° in XZ.
static func is_ortho_or_45(points: PackedVector3Array, tol_deg: float = 2.0) -> bool:
	if points.size() < 2:
		return true
	var tol := deg_to_rad(tol_deg)
	for i: int in range(points.size() - 1):
		var d: Vector3 = points[i + 1] - points[i]
		var hz := Vector2(d.x, d.z)
		if hz.length() < 1e-4:
			continue  # pure vertical ok
		var ang := absf(atan2(hz.y, hz.x))
		# Normalize to [0, PI/2]
		while ang > PI * 0.5:
			ang -= PI * 0.5
		var nearest := 0.0
		if absf(ang - PI * 0.25) < absf(ang - nearest):
			nearest = PI * 0.25
		if absf(ang - PI * 0.5) < absf(ang - nearest):
			nearest = PI * 0.5
		if absf(ang - nearest) > tol:
			return false
	return true
