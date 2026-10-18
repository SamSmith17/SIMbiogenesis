class_name ContourRouter
extends RefCounted

## Terrain-following router for penstock-style runs (poly_penstock): samples the
## ground along the XZ path, lifts by a small clearance, and smooths the profile
## so the pipe never bends tighter than its minimum cold-bend radius — it
## bridges gullies sharper than the pipe can dip into and lifts off ahead of
## crests sharper than it can arc over. This is the route mode the two prior
## terrain-following attempts (ConduitOrthoRouter.metro_ground_route's mean-Y
## flatten, ConduitPipesRouter + ground_fn's dive-to-the-floor) were missing:
## the ground samples ARE the route, so the mesh builder must never re-drape it.
##
## Pure static + deterministic (fixed step policy, iteration-capped smoothing) —
## the ConduitRouteDispatch preview==commit invariant depends on identical
## output for identical inputs. `ground_fn` is Callable(pos: Vector3) -> float
## — the ConduitManager.ground_y_at / ConduitMeshBuilder convention (only the
## XZ of the probe point is read).

## Target ground-sample spacing along the run. Grows when a long run would
## exceed MAX_SAMPLES (cf. ElevationProfile.LAB_MAX_SAMPLES — same budget class).
const STEP_M := 1.0
const MAX_SAMPLES := 160
const MIN_SAMPLES_PER_LEG := 4
## Pipe rests just proud of the ground (matches ConduitMeshBuilder's
## DRAPE_CLEARANCE_M scale — half a pipe diameter of daylight, not a trench).
const CLEARANCE_M := 0.05
## Up-only second-difference relaxation passes. Each pass only ever RAISES
## points (ground is a hard lower bound), so the fixpoint is well-defined and
## the cap just bounds work on pathological terrain.
const RELAX_ITERS := 48
## Blend the first/last samples toward the port heights over this many steps so
## the run meets its seated approach points instead of stepping off the ground.
const END_BLEND_STEPS := 3
## Horizontal corner fillets: arc samples per corner (EVEN, so the middle
## sample is the pin itself), and the largest share of the shorter adjoining
## leg an arc's half-chord may take (a corner whose legs are too short for the
## pipe's radius gets the biggest arc that fits and is reported as a tight
## bend).
const FILLET_SAMPLES := 6
const FILLET_MAX_LEG_FRAC := 0.45
## route_report measures curvature on a resample at this spacing — the arc
## chords are sub-metre and three samples on one chord read as a kink.
const REPORT_STEP_M := 1.0
## Port approaches excluded from the bend report (each end).
const APPROACH_SKIP_M := 2.5
## A turn under this is a straight (numerical noise on a 1 m step).
const BEND_TURN_MIN_DEG := 1.0


## Route through `points` (route ends + optional player waypoints, in order).
## Heights of the input points are respected AT the points (they are port
## approaches / pinned positions); between them the ground owns the profile.
static func route_polyline(points: Array, ground_fn: Callable,
		min_bend_radius_m: float, clearance_m: float = CLEARANCE_M) -> PackedVector3Array:
	var out := PackedVector3Array()
	var pts: Array = []
	for p: Variant in points:
		if p is Vector3 and is_finite((p as Vector3).x):
			pts.append(p as Vector3)
	if pts.size() < 2:
		for p: Vector3 in pts:
			out.append(p)
		return out
	# Coiled pipe cannot turn a corner: round every interior joint in plan at
	# the cold-bend radius (the vertical pass below handles the profile). The
	# arc samples sit on the ground like any other sample.
	if min_bend_radius_m > 0.01 and pts.size() >= 3:
		pts = fillet_xz(pts, min_bend_radius_m, ground_fn, clearance_m)
	# Total XZ length decides the sample step (budgeted).
	var total_xz := 0.0
	for i in range(pts.size() - 1):
		total_xz += Vector2(pts[i].x, pts[i].z).distance_to(
				Vector2(pts[i + 1].x, pts[i + 1].z))
	var step := maxf(STEP_M, total_xz / float(MAX_SAMPLES))
	var have_ground := ground_fn.is_valid()
	for leg in range(pts.size() - 1):
		var a: Vector3 = pts[leg]
		var b: Vector3 = pts[leg + 1]
		var xz_len := Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))
		# A fillet's arc chords are sub-metre: one sample each, not four.
		var min_n := MIN_SAMPLES_PER_LEG if xz_len > 2.0 * step else 1
		var n := maxi(int(ceilf(xz_len / step)), min_n)
		var i0 := 1 if leg > 0 else 0  # legs share their joint point once
		for i in range(i0, n + 1):
			var t := float(i) / float(n)
			var pos := a.lerp(b, t)
			if have_ground:
				var gy := float(ground_fn.call(pos)) + clearance_m
				# Endpoints (and pinned joints) keep their own height; blend
				# the neighbouring samples so the run meets them smoothly.
				var blend := 1.0
				if leg == 0 and i < END_BLEND_STEPS:
					blend = float(i) / float(END_BLEND_STEPS)
				elif leg == pts.size() - 2 and i > n - END_BLEND_STEPS:
					blend = float(n - i) / float(END_BLEND_STEPS)
				if i == 0 or i == n:
					blend = 0.0 if (leg == 0 and i == 0) \
							or (leg == pts.size() - 2 and i == n) else blend
				# Interior joints (player pins) also keep their height.
				if i == n and leg < pts.size() - 2:
					blend = 0.0
				pos.y = lerpf(pos.y, gy, clampf(blend, 0.0, 1.0)) \
						if blend < 1.0 else gy
			out.append(pos)
	if have_ground and min_bend_radius_m > 0.01:
		_relax_bend_radius(out, step, min_bend_radius_m)
	return out


## Enforce the vertical curvature bound |y″| ≤ 1/R via the discrete second
## difference: |y[i−1] − 2y[i] + y[i+1]| ≤ h²/R. Moves points UP only —
## a too-sharp valley raises its centre (the pipe bridges the dip), a too-sharp
## crest raises the neighbours (the pipe lifts off approaching the top) — so
## the ground stays a hard lower bound and the iteration is monotone.
## Endpoints are pinned (they sit on ports).
static func _relax_bend_radius(pts: PackedVector3Array, step_m: float,
		r_min_m: float) -> void:
	var n := pts.size()
	if n < 3:
		return
	var limit := (step_m * step_m) / maxf(r_min_m, 0.01)
	for _pass in range(RELAX_ITERS):
		var moved := false
		for i in range(1, n - 1):
			var d2 := pts[i - 1].y - 2.0 * pts[i].y + pts[i + 1].y
			if d2 > limit:
				# Valley sharper than the pipe can dip into — raise the centre.
				var p := pts[i]
				p.y += (d2 - limit) * 0.5
				pts[i] = p
				moved = true
			elif d2 < -limit:
				# Crest sharper than the pipe can arc over — lift the shoulders.
				var lift := (-d2 - limit) * 0.25
				if i - 1 > 0:
					var pl := pts[i - 1]
					pl.y += lift
					pts[i - 1] = pl
					moved = true
				if i + 1 < n - 1:
					var pr := pts[i + 1]
					pr.y += lift
					pts[i + 1] = pr
					moved = true
		if not moved:
			break


## Round each interior corner of `pts` (Vector3, world) with a circular arc
## of radius `r_m` in the XZ plane whose APEX is the corner point itself — a
## player's pin (or a stream vertex) stays ON the pipe, exactly as an
## installer lays coil past a stake, and the straight legs run to the arc's
## ends instead of to the stake. The arc's half-chord is capped at
## FILLET_MAX_LEG_FRAC of the shorter leg, so a corner with short legs gets
## the biggest arc that fits (and reads as a tight bend in route_report).
## Endpoints untouched. Pure + deterministic.
static func fillet_xz(pts: Array, r_m: float, ground_fn: Callable = Callable(),
		clearance_m: float = CLEARANCE_M) -> Array:
	var out: Array = [pts[0]]
	var have_ground := ground_fn.is_valid()
	for i in range(1, pts.size() - 1):
		var p: Vector3 = pts[i]
		var prev: Vector3 = out[out.size() - 1]
		var next: Vector3 = pts[i + 1]
		var p2 := Vector2(p.x, p.z)
		var u := p2 - Vector2(prev.x, prev.z)
		var v := Vector2(next.x, next.z) - p2
		var lu := u.length()
		var lv := v.length()
		if lu < 1e-4 or lv < 1e-4:
			out.append(p)
			continue
		u /= lu
		v /= lv
		var turn := acos(clampf(u.dot(v), -1.0, 1.0))
		if turn < deg_to_rad(BEND_TURN_MIN_DEG) or turn > deg_to_rad(170.0):
			out.append(p)
			continue
		# Half-chord of an arc of radius r subtending the turn is r·sin(φ/2).
		var half := minf(r_m * sin(turn * 0.5), FILLET_MAX_LEG_FRAC * minf(lu, lv))
		var r := half / maxf(sin(turn * 0.5), 1e-4)
		# Centre on the interior bisector, r from the apex.
		var bis := (v - u).normalized()
		var c2 := p2 + bis * r
		var apex_ang := (p2 - c2).angle()
		# Sweep direction: the arc end nearer `prev` comes first (decided by
		# distance, not by a handedness rule that depends on Vector2.angle's
		# convention in the XZ plane).
		var end_a := c2 + Vector2(cos(apex_ang - 0.5 * turn), sin(apex_ang - 0.5 * turn)) * r
		var end_b := c2 + Vector2(cos(apex_ang + 0.5 * turn), sin(apex_ang + 0.5 * turn)) * r
		var prev2 := Vector2(prev.x, prev.z)
		var sgn := 1.0 if end_a.distance_squared_to(prev2) <= end_b.distance_squared_to(prev2) else -1.0
		for k in range(0, FILLET_SAMPLES + 1):
			var f := float(k) / float(FILLET_SAMPLES) - 0.5   # −½ … +½, 0 = the apex
			var ang := apex_ang + sgn * f * turn
			var xz := c2 + Vector2(cos(ang), sin(ang)) * r
			var y := lerpf(prev.y, next.y, f + 0.5)
			if k == FILLET_SAMPLES / 2:
				xz = p2
				y = p.y
			elif have_ground:
				y = float(ground_fn.call(Vector3(xz.x, 0.0, xz.y))) + clearance_m
			out.append(Vector3(xz.x, y, xz.y))
	out.append(pts[pts.size() - 1])
	return out


## Resample a polyline at a fixed arc-length spacing (first/last kept).
static func resample(pts: PackedVector3Array, spacing_m: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	if pts.size() == 0:
		return out
	out.append(pts[0])
	var carry := 0.0
	for i in range(1, pts.size()):
		var a := pts[i - 1]
		var b := pts[i]
		var seg := a.distance_to(b)
		var d := spacing_m - carry
		while d <= seg and seg > 1e-9:
			out.append(a.lerp(b, d / seg))
			d += spacing_m
		carry = seg - (d - spacing_m)
	if not out[out.size() - 1].is_equal_approx(pts[pts.size() - 1]):
		out.append(pts[pts.size() - 1])
	return out


## What a routed run looks like to the pipe: {min_bend_r_m (plan + profile,
## INF when straight), high_points (local crests with ≥ 0.3 m prominence,
## excluding the ends), high_point_pos (Array of Vector3),
## rise_above_intake_m (how far the run climbs above its FIRST point — a
## siphon leg), length_m}. The intake is taken as the first point.
## Which pinned corners could NOT take the full cold-bend fillet because a
## leg beside them is too short (fillet_xz fits the biggest arc that fits —
## FILLET_MAX_LEG_FRAC of the shorter leg). The route then carries a bend
## tighter than the pipe's radius BY THE PLAYER'S OWN PINS, not by a routing
## fault: a hand-drawn creek with 2 m legs cannot take a 1.5 m arc. Returns
## {short_leg_m: the shortest limiting leg (-1.0 when every corner fits),
## corners: how many were limited}. Pure; `pins` is the pre-fillet polyline.
static func short_leg_report(pins: Array, r_m: float) -> Dictionary:
	var rep := {"short_leg_m": -1.0, "corners": 0}
	if r_m <= 0.01 or pins.size() < 3:
		return rep
	var shortest := INF
	for i in range(1, pins.size() - 1):
		var p: Vector3 = pins[i]
		var prev: Vector3 = pins[i - 1]
		var next: Vector3 = pins[i + 1]
		var u := Vector2(p.x, p.z) - Vector2(prev.x, prev.z)
		var v := Vector2(next.x, next.z) - Vector2(p.x, p.z)
		var lu := u.length()
		var lv := v.length()
		if lu < 1e-4 or lv < 1e-4:
			continue
		var turn := acos(clampf(u.dot(v) / (lu * lv), -1.0, 1.0))
		if turn < deg_to_rad(BEND_TURN_MIN_DEG) or turn > deg_to_rad(170.0):
			continue
		var want_half := r_m * sin(turn * 0.5)
		var leg := minf(lu, lv)
		if FILLET_MAX_LEG_FRAC * leg < want_half:
			rep["corners"] = int(rep["corners"]) + 1
			shortest = minf(shortest, leg)
	if is_finite(shortest):
		rep["short_leg_m"] = shortest
	return rep


static func route_report(raw: PackedVector3Array) -> Dictionary:
	var rep := {"min_bend_r_m": INF, "high_points": 0, "high_point_pos": [],
		"rise_above_intake_m": 0.0, "length_m": polyline_length_m(raw)}
	if raw.size() < 3:
		return rep
	var pts := resample(raw, REPORT_STEP_M)
	var n := pts.size()
	if n < 3:
		return rep
	var min_r := INF
	var min_turn := deg_to_rad(BEND_TURN_MIN_DEG)
	# The first / last couple of metres are the seated port approaches — a
	# collar or an inlet elbow, a FITTING, not bent coil — so they are not
	# measured against the cold-bend radius.
	var skip := int(ceilf(APPROACH_SKIP_M / REPORT_STEP_M))
	for i in range(maxi(1, skip), mini(n - 1, n - skip)):
		var a := pts[i - 1]
		var b := pts[i]
		var c := pts[i + 1]
		# Plan radius.
		var r_xz := _circumradius(Vector2(a.x, a.z), Vector2(b.x, b.z), Vector2(c.x, c.z), min_turn)
		min_r = minf(min_r, r_xz)
		# Profile radius (arc length along the run vs height).
		var s1 := Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))
		var s2 := Vector2(b.x, b.z).distance_to(Vector2(c.x, c.z))
		var r_y := _circumradius(Vector2(0.0, a.y), Vector2(s1, b.y), Vector2(s1 + s2, c.y), min_turn)
		min_r = minf(min_r, r_y)
	rep["min_bend_r_m"] = min_r
	# High points: a crest above both neighbouring troughs by the prominence.
	var hp_pos: Array = []
	var i := 1
	while i < n - 1:
		if pts[i].y > pts[i - 1].y and pts[i].y >= pts[i + 1].y:
			# Walk outward to the troughs.
			var lo_l := pts[i].y
			var j := i - 1
			while j >= 0 and pts[j].y <= pts[j + 1].y:
				lo_l = minf(lo_l, pts[j].y)
				j -= 1
			var lo_r := pts[i].y
			var k := i + 1
			while k < n and pts[k].y <= pts[k - 1].y:
				lo_r = minf(lo_r, pts[k].y)
				k += 1
			if pts[i].y - maxf(lo_l, lo_r) >= 0.3:
				hp_pos.append(pts[i])
		i += 1
	rep["high_points"] = hp_pos.size()
	rep["high_point_pos"] = hp_pos
	var top := pts[0].y
	for p in pts:
		top = maxf(top, p.y)
	rep["rise_above_intake_m"] = maxf(top - pts[0].y, 0.0)
	return rep


## Circumradius of three points; INF when they are (nearly) collinear.
static func _circumradius(a: Vector2, b: Vector2, c: Vector2, min_turn_rad: float) -> float:
	var u := b - a
	var v := c - b
	if u.length() < 1e-6 or v.length() < 1e-6:
		return INF
	var turn := acos(clampf(u.normalized().dot(v.normalized()), -1.0, 1.0))
	if turn < min_turn_rad:
		return INF
	var ab := u.length()
	var bc := v.length()
	var ca := (a - c).length()
	var area2 := absf(u.cross(v))
	if area2 < 1e-9:
		return INF
	return ab * bc * ca / (2.0 * area2)


## Polyline length (m) of a routed run — the honest "total run" the flow
## engine feeds HydroReach as penstock length.
static func polyline_length_m(pts: PackedVector3Array) -> float:
	var total := 0.0
	for i in range(1, pts.size()):
		total += pts[i - 1].distance_to(pts[i])
	return total
