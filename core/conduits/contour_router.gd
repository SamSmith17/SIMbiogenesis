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
		var n := maxi(int(ceilf(xz_len / step)), MIN_SAMPLES_PER_LEG)
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


## Polyline length (m) of a routed run — the honest "total run" the flow
## engine feeds HydroReach as penstock length.
static func polyline_length_m(pts: PackedVector3Array) -> float:
	var total := 0.0
	for i in range(1, pts.size()):
		total += pts[i - 1].distance_to(pts[i])
	return total
