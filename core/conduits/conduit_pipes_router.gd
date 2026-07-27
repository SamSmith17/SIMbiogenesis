class_name ConduitPipesRouter
extends RefCounted

## 3D-Pipes routing: straight rigid sections joined by standard elbow fittings.
##
## Two modes, chosen by `fitting_step_deg`:
##   * 0  → classic axis-aligned screensaver (90° elbows only). Vertical risers at
##          each end, horizontal L-staircase between corners.
##   * >0 → real PVC/ABS-style runs where every horizontal bend is EXACTLY
##          `fitting_step_deg` degrees (30 / 45 / 60 / 90 — the common fitting
##          angles). Diagonal runs are supported: a leg is split into two lattice-
##          heading segments meeting at one `step`° elbow, solved so the endpoint
##          is hit exactly (no drift). Vertical change stays as clean risers.
##
## Used for PVC / duct / conceptual runs (replaces the old metro corridor).

const DEFAULT_CLEARANCE_M := 0.12
const DEFAULT_ELBOW_FRAC := 0.50
const JOG_CLEARANCE_M := 0.55

## Standard fitting angles (degrees) real PVC/ABS assemblies are built from. A
## per-run `fitting_step_deg` should normally be one of these; `snap_fitting_angle`
## rounds an arbitrary request to the nearest.
const STANDARD_FITTING_ANGLES: Array = [30.0, 45.0, 60.0, 90.0]


## Route A→B with optional mid waypoints. `ground_y_fn(Vector3)->float` optional
## for clearance-band height when endpoints are elevated plugs.
## `fitting_step_deg`: 0 = axis-only 90° elbows; >0 = every horizontal bend snaps
## to that fitting angle (diagonal runs allowed).
static func route(a: Vector3, b: Vector3, waypoints: Array = [],
		ground_y_fn: Callable = Callable(),
		clearance_m: float = DEFAULT_CLEARANCE_M,
		elbow_radius_frac: float = DEFAULT_ELBOW_FRAC,
		obstacles: Array = [],
		fitting_step_deg: float = 0.0) -> PackedVector3Array:
	var corners := _build_corners(a, b, waypoints, ground_y_fn, clearance_m, fitting_step_deg)
	corners = _insert_obstacle_jogs(corners, obstacles)
	var sharp := PackedVector3Array()
	for c: Variant in corners:
		if c is Vector3:
			sharp.append(c as Vector3)
	sharp = _dedupe(sharp)
	if sharp.size() < 2:
		return PackedVector3Array([a, b])
	# Standard-fitting (or axis) spans between corners, then soft elbows.
	var axis := PackedVector3Array()
	axis.append(sharp[0])
	for i: int in range(sharp.size() - 1):
		var span := _span(sharp[i], sharp[i + 1], fitting_step_deg)
		for j: int in range(1, span.size()):
			axis.append(span[j])
	axis = _dedupe(axis)
	if elbow_radius_frac <= 0.001:
		return axis
	return ConduitOrthoRouter.soften_elbows(axis, ConduitOrthoRouter.ELBOW_SAMPLES,
		elbow_radius_frac)


## Nearest real fitting angle to an arbitrary request (defaults to 45° for 0/invalid).
static func snap_fitting_angle(deg: float) -> float:
	if deg <= 0.5:
		return 0.0
	var best := STANDARD_FITTING_ANGLES[0] as float
	var best_d := absf(deg - best)
	for v: float in STANDARD_FITTING_ANGLES:
		var d := absf(deg - v)
		if d < best_d:
			best_d = d
			best = v
	return best


## One span between two (equal-Y) corners: fitting dogleg when step>0, else axis L.
static func _span(a: Vector3, b: Vector3, step_deg: float) -> Array:
	if step_deg > 0.5:
		return _fitting_span(a, b, step_deg)
	return _axis_span(a, b)


## Split a horizontal leg into two lattice-heading segments meeting at one exact
## `step`° elbow, solving segment lengths so the far endpoint is hit precisely.
## dir(t)=(cos t, sin t); with bracketing lattice headings t1≤θ<t2 and
## l1·dir(t1)+l2·dir(t2)=Δ, the corner turns by exactly (t2−t1)=step. If θ already
## lies on the lattice the leg is a single straight section.
static func _fitting_span(a: Vector3, b: Vector3, step_deg: float) -> Array:
	var out: Array = [a]
	var d := Vector2(b.x - a.x, b.z - a.z)
	var horiz := d.length()
	if horiz < 1e-4:
		out.append(b)
		return out
	var step := deg_to_rad(clampf(step_deg, 5.0, 90.0))
	var theta := atan2(d.y, d.x)
	var k := floorf(theta / step)
	var t1 := k * step
	var t2 := (k + 1.0) * step
	var det := sin(t2 - t1)  # = sin(step)
	if absf(det) < 1e-6:
		out.append(b)
		return out
	var l1 := (d.x * sin(t2) - d.y * cos(t2)) / det
	var l2 := (-d.x * sin(t1) + d.y * cos(t1)) / det
	# θ already on the lattice → one straight run (no sub-millimetre elbow).
	if l1 < 1e-3 or l2 < 1e-3:
		out.append(b)
		return out
	var corner := a + Vector3(cos(t1) * l1, 0.0, sin(t1) * l1)
	corner.y = a.y
	out.append(corner)
	out.append(b)
	return out


## Largest horizontal (XZ) turn angle between consecutive segments, in degrees.
## Used to verify a fitting run's bends match the requested standard angle.
## Vertical-only segments (risers) are skipped.
static func max_horizontal_bend_deg(points: PackedVector3Array) -> float:
	var worst := 0.0
	for i: int in range(1, points.size() - 1):
		var v0 := Vector2(points[i].x - points[i - 1].x, points[i].z - points[i - 1].z)
		var v1 := Vector2(points[i + 1].x - points[i].x, points[i + 1].z - points[i].z)
		if v0.length() < 1e-3 or v1.length() < 1e-3:
			continue
		var ang := rad_to_deg(v0.angle_to(v1))
		worst = maxf(worst, absf(ang))
	return worst


## True when every segment is purely axis-aligned (no diagonals).
static func is_axis_only(points: PackedVector3Array, tol: float = 0.02) -> bool:
	for i: int in range(points.size() - 1):
		var d: Vector3 = points[i + 1] - points[i]
		var nz := 0
		if absf(d.x) > tol:
			nz += 1
		if absf(d.y) > tol:
			nz += 1
		if absf(d.z) > tol:
			nz += 1
		if nz > 1:
			return false
	return true


static func _build_corners(a: Vector3, b: Vector3, waypoints: Array,
		ground_y_fn: Callable, clearance_m: float,
		fitting_step_deg: float = 0.0) -> Array:
	var corners: Array = []
	corners.append(a)
	var ya := a.y
	var yb := b.y
	if ground_y_fn.is_valid():
		ya = float(ground_y_fn.call(a)) + clearance_m
		yb = float(ground_y_fn.call(b)) + clearance_m
	# Shared run height: prefer mean of cleared ground, but never above the
	# lower plug by much — classic pipes drop to a band then run.
	var y_run := (ya + yb) * 0.5
	# Drop from A to run band if elevated.
	if absf(a.y - y_run) > 0.08:
		corners.append(Vector3(a.x, y_run, a.z))
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
		mids.append(Vector3(p.x, y_run, p.z))
	# Chain through mids with axis preference (longer horizontal delta first).
	var cur: Vector3 = corners[corners.size() - 1] as Vector3
	var targets: Array = mids.duplicate()
	targets.append(Vector3(b.x, y_run, b.z))
	for t: Variant in targets:
		var dest: Vector3 = t as Vector3
		for step: Variant in _span(cur, dest, fitting_step_deg):
			var s: Vector3 = step as Vector3
			if (corners[corners.size() - 1] as Vector3).distance_to(s) > 0.02:
				corners.append(s)
		cur = dest
	# Rise to B.
	if absf(b.y - y_run) > 0.08:
		corners.append(b)
	elif (corners[corners.size() - 1] as Vector3).distance_to(b) > 0.02:
		corners.append(b)
	return corners


## Pure axis-aligned span: longer horizontal axis first, then the other, then Y.
static func _axis_span(a: Vector3, b: Vector3) -> Array:
	var out: Array = [a]
	if a.distance_to(b) < 1e-4:
		out.append(b)
		return out
	var dx := b.x - a.x
	var dy := b.y - a.y
	var dz := b.z - a.z
	var ax := absf(dx)
	var az := absf(dz)
	var cur := a
	if ax >= az:
		if ax > 1e-4:
			cur = Vector3(b.x, cur.y, cur.z)
			out.append(cur)
		if az > 1e-4:
			cur = Vector3(cur.x, cur.y, b.z)
			out.append(cur)
	else:
		if az > 1e-4:
			cur = Vector3(cur.x, cur.y, b.z)
			out.append(cur)
		if ax > 1e-4:
			cur = Vector3(b.x, cur.y, cur.z)
			out.append(cur)
	if absf(dy) > 1e-4 or cur.distance_to(b) > 1e-4:
		out.append(b)
	return out


static func _insert_obstacle_jogs(corners: Array, obstacles: Array) -> Array:
	if obstacles.is_empty() or corners.size() < 2:
		return corners
	var out: Array = [corners[0]]
	for i: int in range(corners.size() - 1):
		var from: Vector3 = corners[i] as Vector3
		var to: Vector3 = corners[i + 1] as Vector3
		var jogged := false
		for obs: Variant in obstacles:
			if not (obs is AABB):
				continue
			var box: AABB = (obs as AABB).grow(JOG_CLEARANCE_M)
			if not _segment_hits_aabb_xz(from, to, box):
				continue
			var center := box.get_center()
			var dx := to.x - from.x
			var dz := to.z - from.z
			# Side jog perpendicular to the dominant horizontal run.
			var side: Vector3
			if absf(dx) >= absf(dz):
				var sz := 1.0 if (center.z - from.z) >= 0.0 else -1.0
				if absf(center.z - from.z) < 0.05:
					sz = 1.0
				var jog_z := center.z + sz * (box.size.z * 0.5 + JOG_CLEARANCE_M)
				out.append(Vector3(from.x, from.y, jog_z))
				out.append(Vector3(to.x, from.y, jog_z))
			else:
				var sx := 1.0 if (center.x - from.x) >= 0.0 else -1.0
				if absf(center.x - from.x) < 0.05:
					sx = 1.0
				var jog_x := center.x + sx * (box.size.x * 0.5 + JOG_CLEARANCE_M)
				out.append(Vector3(jog_x, from.y, from.z))
				out.append(Vector3(jog_x, from.y, to.z))
			jogged = true
			break
		if not jogged:
			pass
		out.append(to)
	return out


static func _segment_hits_aabb_xz(a: Vector3, b: Vector3, box: AABB) -> bool:
	for t: float in [0.25, 0.5, 0.75]:
		var p := a.lerp(b, t)
		if p.x >= box.position.x and p.x <= box.position.x + box.size.x \
				and p.z >= box.position.z and p.z <= box.position.z + box.size.z:
			return true
	return false


static func _dedupe(pts: PackedVector3Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	for p: Vector3 in pts:
		if out.is_empty() or out[out.size() - 1].distance_to(p) > 0.02:
			out.append(p)
	return out
