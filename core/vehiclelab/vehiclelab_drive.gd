class_name VehicleDrive
extends RefCounted

## A living vehicle DRIVING IN through the site gate, and DRIVING OUT again —
## a pure function of sim time, the fire timeline's rule. The prop record carries `arrival` =
## {start_h, route: [[x, z], …] control points from the gate to the parking
## spot, park: [x, z, yaw_deg]}; `pose_at(arrival, abs_h)` says where the
## vehicle is. Nothing is integrated, so a drive scrubs backwards, survives a
## reload and plays the same at any clock speed.
##
## The record's own x / z / yaw stay the PARKED pose; before `start_h` the
## vehicle is not on site yet (AWAY), then it drives the route (DRIVING), then
## it stands where it was placed (PARKED).
##
## Leaving: the record carries `departure` = {start_h, route: [park spot,
## the pull-out point ahead of it, the road, the gate, outside], park, out:
## true}; before `start_h` the vehicle is PARKED, then it drives out
## (DRIVING), then it is gone (AWAY). `pose_of(rec, abs_h)` reads both.
##
## Speed: a festival road at ~13 mph, slowed through bends to v = sqrt(a·r)
## with a comfortable lateral acceleration, a creep over the last straight
## into the spot, accelerating and braking at a comfortable rate. Constants
## are driving-comfort figures (AASHTO's comfortable deceleration is 3.4 m/s²;
## a loaded camper on gravel is driven far gentler), not physics limits.

const STATE_AWAY := "away"
const STATE_DRIVING := "driving"
const STATE_PARKED := "parked"

const CRUISE_MS := 6.0
const APPROACH_MS := 1.5
const ACCEL_MS2 := 0.8
const DECEL_MS2 := 0.6
## Lateral acceleration through a bend (m/s²): v_max = sqrt(a · r).
const CORNER_LAT_MS2 := 1.2
const SAMPLE_M := 2.0
## The last straight run into the spot, along the parked heading.
const APPROACH_M := 14.0
## Vehicles set off this far apart (a gate lets one through at a time).
const DEFAULT_SPACING_H := 4.0 / 60.0
## A road counts as "the way in" when the gate and the spot are both this
## close to it.
const ROAD_SNAP_M := 120.0

## Cached plans, oldest dropped past PLAN_CACHE_MAX.
const PLAN_CACHE_MAX := 64
static var _plans: Dictionary = {}


## Forward (the rider's -Z) for a yaw in radians, as world XZ.
static func forward(yaw: float) -> Vector2:
	return Vector2(-sin(yaw), -cos(yaw))


static func yaw_for(dir: Vector2) -> float:
	return atan2(-dir.x, -dir.y)


## The approach point: APPROACH_M behind the parking spot along its heading.
static func approach_point(park_xz: Vector2, park_yaw_deg: float) -> Vector2:
	return park_xz - forward(deg_to_rad(park_yaw_deg)) * APPROACH_M


## The control points from the gate to the spot: along a festival road when
## one passes near both (the stretch between the points nearest the gate and
## the approach), else straight.
static func route_points(gate: Vector2, park_xz: Vector2, park_yaw_deg: float,
		roads: Array = [], entry: Vector2 = Vector2.INF) -> Array:
	var appr := approach_point(park_xz, park_yaw_deg)
	var pts: Array = [gate] if not entry.is_finite() else [entry, gate]
	var best_cost := INF
	var best_road: PackedVector2Array = PackedVector2Array()
	var best_a := {}
	var best_b := {}
	for r in roads:
		var poly: PackedVector2Array = PackedVector2Array((r as Dictionary).get("points", PackedVector2Array()))
		if poly.size() < 2:
			continue
		var a := _nearest_on(poly, gate)
		var b := _nearest_on(poly, appr)
		var cost := float(a["d"]) + float(b["d"])
		if float(a["d"]) <= ROAD_SNAP_M and float(b["d"]) <= ROAD_SNAP_M and cost < best_cost:
			best_cost = cost
			best_road = poly
			best_a = a
			best_b = b
	if not best_road.is_empty():
		for p in _sub_polyline(best_road, float(best_a["s"]), float(best_b["s"])):
			if (pts[pts.size() - 1] as Vector2).distance_to(p) > 3.0:
				pts.append(p)
	if (pts[pts.size() - 1] as Vector2).distance_to(appr) > 3.0:
		pts.append(appr)
	pts.append(park_xz)
	return pts


## The pull-out point: APPROACH_M ahead of the parking spot along its
## heading (a vehicle leaves nose first, the way it came in).
static func exit_point(park_xz: Vector2, park_yaw_deg: float) -> Vector2:
	return park_xz + forward(deg_to_rad(park_yaw_deg)) * APPROACH_M


## The way out: the spot, the pull-out point, along the road nearest both the
## pull-out and the gate, the gate, then outside it.
static func route_points_out(gate: Vector2, park_xz: Vector2, park_yaw_deg: float,
		roads: Array = [], exit_to: Vector2 = Vector2.INF) -> Array:
	var ex := exit_point(park_xz, park_yaw_deg)
	var pts: Array = [park_xz, ex]
	var best_cost := INF
	var best_road: PackedVector2Array = PackedVector2Array()
	var best_a := {}
	var best_b := {}
	for r in roads:
		var poly: PackedVector2Array = PackedVector2Array((r as Dictionary).get("points", PackedVector2Array()))
		if poly.size() < 2:
			continue
		var a := _nearest_on(poly, ex)
		var b := _nearest_on(poly, gate)
		var cost := float(a["d"]) + float(b["d"])
		if float(a["d"]) <= ROAD_SNAP_M and float(b["d"]) <= ROAD_SNAP_M and cost < best_cost:
			best_cost = cost
			best_road = poly
			best_a = a
			best_b = b
	if not best_road.is_empty():
		for p in _sub_polyline(best_road, float(best_a["s"]), float(best_b["s"])):
			if (pts[pts.size() - 1] as Vector2).distance_to(p) > 3.0:
				pts.append(p)
	if (pts[pts.size() - 1] as Vector2).distance_to(gate) > 3.0:
		pts.append(gate)
	if exit_to.is_finite() and gate.distance_to(exit_to) > 1.0:
		pts.append(exit_to)
	return pts


## The departure record (`exit_to`: where the vehicle is gone, outside the
## gate; INF = at the gate itself).
static func make_out(gate: Vector2, park_xz: Vector2, park_yaw_deg: float, start_h: float,
		roads: Array = [], exit_to: Vector2 = Vector2.INF) -> Dictionary:
	var route: Array = []
	for p in route_points_out(gate, park_xz, park_yaw_deg, roads, exit_to):
		route.append([snappedf((p as Vector2).x, 0.01), snappedf((p as Vector2).y, 0.01)])
	return {"start_h": start_h, "route": route,
		"park": [park_xz.x, park_xz.y, park_yaw_deg], "out": true}


## Where a placed vehicle record is at `abs_h` through its arrival and its
## departure (either may be missing): the pose_at dict. With neither, or
## between the two, it is PARKED at the record's own pose.
static func pose_of(rec: Dictionary, abs_h: float) -> Dictionary:
	var a: Variant = rec.get("arrival")
	var dp: Variant = rec.get("departure")
	var arr: Dictionary = a if a is Dictionary else {}
	var dep: Dictionary = dp if dp is Dictionary else {}
	return pose_for(arr, dep, abs_h, Vector2(float(rec.get("x", 0.0)), float(rec.get("z", 0.0))),
		deg_to_rad(float(rec.get("yaw", 0.0))))


static func pose_for(arr: Dictionary, dep: Dictionary, abs_h: float,
		park_pos: Vector2 = Vector2.ZERO, park_yaw: float = 0.0) -> Dictionary:
	if not dep.is_empty() and abs_h >= float(dep.get("start_h", INF)):
		return pose_at(dep, abs_h)
	if not arr.is_empty():
		return pose_at(arr, abs_h)
	return {"state": STATE_PARKED, "pos": park_pos, "yaw": park_yaw, "speed": 0.0, "u": 1.0, "s": 0.0}


## Whether the vehicle stands in its spot at `abs_h` (the hours it can be
## loaded, unloaded, got into, and its camp is home).
static func parked_at(rec: Dictionary, abs_h: float) -> bool:
	return str(pose_of(rec, abs_h)["state"]) == STATE_PARKED


## The hour it leaves its spot, INF when no departure is set.
static func leave_h(rec: Dictionary) -> float:
	var dp: Variant = rec.get("departure")
	if not (dp is Dictionary) or (dp as Dictionary).is_empty():
		return INF
	return float((dp as Dictionary).get("start_h", INF))


## The hour it is gone through the gate, INF when no departure is set.
static func gone_h(rec: Dictionary) -> float:
	var dp: Variant = rec.get("departure")
	if not (dp is Dictionary) or (dp as Dictionary).is_empty():
		return INF
	return float((dp as Dictionary).get("start_h", 0.0)) + duration_h(dp)


## The arrival record. `entry`: where the vehicle appears, outside the gate
## (SiteGateBuilder.approach_xz); INF = at the gate itself.
static func make(gate: Vector2, park_xz: Vector2, park_yaw_deg: float, start_h: float,
		roads: Array = [], entry: Vector2 = Vector2.INF) -> Dictionary:
	var route: Array = []
	for p in route_points(gate, park_xz, park_yaw_deg, roads, entry):
		route.append([snappedf((p as Vector2).x, 0.01), snappedf((p as Vector2).y, 0.01)])
	return {"start_h": start_h, "route": route,
		"park": [park_xz.x, park_xz.y, park_yaw_deg]}


## The densified path + time table (cached by the record's route): {pts,
## yaws, t (seconds from the start), v, dur_s, length}.
static func plan(arrival: Dictionary) -> Dictionary:
	var out_bound := bool(arrival.get("out", false))
	var key := JSON.stringify([arrival.get("route", []), arrival.get("park", []), out_bound])
	if _plans.has(key):
		return _plans[key]
	if _plans.size() >= PLAN_CACHE_MAX:
		_plans.erase(_plans.keys()[0])
	var ctrl: Array = []
	for p in arrival.get("route", []):
		if p is Array and (p as Array).size() >= 2:
			ctrl.append(Vector2(float(p[0]), float(p[1])))
	var out := {"pts": PackedVector2Array(), "yaws": PackedFloat32Array(),
		"t": PackedFloat64Array(), "v": PackedFloat32Array(), "dur_s": 0.0, "length": 0.0}
	if ctrl.size() < 2:
		_plans[key] = out
		return out
	var pts := _densify(ctrl)
	var n := pts.size()
	var park: Array = arrival.get("park", [])
	var park_yaw := deg_to_rad(float(park[2])) if park.size() >= 3 else 0.0
	# Arc length.
	var s := PackedFloat64Array()
	s.resize(n)
	for i in range(1, n):
		s[i] = s[i - 1] + pts[i - 1].distance_to(pts[i])
	var total := s[n - 1]
	# Speed cap per sample: cruise, bends, and the creep into the spot.
	var v := PackedFloat32Array()
	v.resize(n)
	for i in n:
		var cap := CRUISE_MS
		if i > 0 and i < n - 1:
			var r := _circumradius(pts[i - 1], pts[i], pts[i + 1])
			cap = minf(cap, sqrt(CORNER_LAT_MS2 * r))
		# The creep: the last straight into the spot, or the first one out.
		var creep := s[i] <= APPROACH_M if out_bound else total - s[i] <= APPROACH_M
		if creep:
			cap = minf(cap, APPROACH_MS)
		v[i] = maxf(cap, 0.5)
	v[0] = 0.0
	v[n - 1] = 0.0
	# Forward pass (accelerate), backward pass (brake).
	for i in range(1, n):
		var ds := s[i] - s[i - 1]
		v[i] = minf(v[i], sqrt(v[i - 1] * v[i - 1] + 2.0 * ACCEL_MS2 * ds))
	for i in range(n - 2, -1, -1):
		var ds2 := s[i + 1] - s[i]
		v[i] = minf(v[i], sqrt(v[i + 1] * v[i + 1] + 2.0 * DECEL_MS2 * ds2))
	# Time table: each step at its mean speed (never under a crawl, or the
	# stop at either end would take forever).
	var t := PackedFloat64Array()
	t.resize(n)
	for i in range(1, n):
		var vm := maxf((v[i] + v[i - 1]) * 0.5, 0.3)
		t[i] = t[i - 1] + (s[i] - s[i - 1]) / vm
	var yaws := PackedFloat32Array()
	yaws.resize(n)
	for i in n:
		var d := (pts[mini(i + 1, n - 1)] - pts[maxi(i - 1, 0)])
		yaws[i] = yaw_for(d) if d.length() > 1e-4 else park_yaw
	if out_bound:
		yaws[0] = park_yaw
	else:
		yaws[n - 1] = park_yaw
	out = {"pts": pts, "yaws": yaws, "t": t, "v": v, "s": s, "dur_s": t[n - 1], "length": total}
	_plans[key] = out
	return out


static func duration_h(arrival: Dictionary) -> float:
	return float(plan(arrival)["dur_s"]) / 3600.0


## The hour the vehicle stands in its spot.
static func park_h(arrival: Dictionary) -> float:
	return float(arrival.get("start_h", 0.0)) + duration_h(arrival)


## Where the vehicle is at `abs_h`: {state, pos: Vector2, yaw (rad), speed
## (m/s), u (0..1 of the route)}.
static func pose_at(arrival: Dictionary, abs_h: float) -> Dictionary:
	var park: Array = arrival.get("park", [0.0, 0.0, 0.0])
	var park_pos := Vector2(float(park[0]), float(park[1])) if park.size() >= 2 else Vector2.ZERO
	var park_yaw := deg_to_rad(float(park[2])) if park.size() >= 3 else 0.0
	var pl := plan(arrival)
	var pts: PackedVector2Array = pl["pts"]
	var t0 := float(arrival.get("start_h", 0.0))
	if pts.size() < 2:
		return {"state": STATE_PARKED, "pos": park_pos, "yaw": park_yaw, "speed": 0.0, "u": 1.0}
	var ts: PackedFloat64Array = pl["t"]
	var el := (abs_h - t0) * 3600.0
	var dur := float(pl["dur_s"])
	if bool(arrival.get("out", false)):
		# Leaving: parked until it sets off, gone once through the gate.
		if el < 0.0:
			return {"state": STATE_PARKED, "pos": park_pos, "yaw": park_yaw, "speed": 0.0, "u": 0.0, "s": 0.0}
		if el >= dur:
			return {"state": STATE_AWAY, "pos": pts[pts.size() - 1],
				"yaw": float((pl["yaws"] as PackedFloat32Array)[pts.size() - 1]),
				"speed": 0.0, "u": 1.0, "s": float(pl["length"])}
	elif el < 0.0:
		return {"state": STATE_AWAY, "pos": pts[0], "yaw": float((pl["yaws"] as PackedFloat32Array)[0]),
			"speed": 0.0, "u": 0.0, "s": 0.0}
	elif el >= dur:
		return {"state": STATE_PARKED, "pos": park_pos, "yaw": park_yaw, "speed": 0.0, "u": 1.0,
			"s": float(pl["length"])}
	# Binary search the time table.
	var lo := 0
	var hi := ts.size() - 1
	while hi - lo > 1:
		var mid := (lo + hi) >> 1
		if ts[mid] <= el:
			lo = mid
		else:
			hi = mid
	var span := maxf(ts[hi] - ts[lo], 1e-6)
	var f := clampf((el - ts[lo]) / span, 0.0, 1.0)
	var yaws: PackedFloat32Array = pl["yaws"]
	var vs: PackedFloat32Array = pl["v"]
	var y := lerp_angle(float(yaws[lo]), float(yaws[hi]), f)
	var ss: PackedFloat64Array = pl["s"]
	return {"state": STATE_DRIVING, "pos": pts[lo].lerp(pts[hi], f), "yaw": y,
		"speed": lerpf(float(vs[lo]), float(vs[hi]), f), "u": el / dur,
		"s": lerpf(ss[lo], ss[hi], f)}


## The point on the path `back_m` behind arc length `s_from` whose distance
## from `from` is `dist` (a towed trailer's axle following its hitch along the
## same road, which is where a trailer runs at road speed). Clamped to the
## route's start, extended straight back past it.
static func point_behind(arrival: Dictionary, from: Vector2, s_from: float, dist: float) -> Vector2:
	var pl := plan(arrival)
	var pts: PackedVector2Array = pl["pts"]
	var ss: PackedFloat64Array = pl["s"]
	if pts.size() < 2:
		return from
	var i := pts.size() - 1
	while i > 0 and ss[i] > s_from:
		i -= 1
	while i >= 0:
		if pts[i].distance_to(from) >= dist:
			# Between pts[i] and the next point toward `from`.
			var nxt := pts[mini(i + 1, pts.size() - 1)]
			var lo := 0.0
			var hi := 1.0
			for _k in 18:
				var m := (lo + hi) * 0.5
				if pts[i].lerp(nxt, m).distance_to(from) >= dist:
					lo = m
				else:
					hi = m
			return pts[i].lerp(nxt, lo)
		i -= 1
	var back := (pts[0] - pts[1]).normalized()
	return from + back * dist if back.length() > 0.0 else from


## The gate's default when none is placed: the end of a festival road
## farthest from the site's centre, else `fallback_m` south of it.
static func default_gate(centre: Vector2, roads: Array, fallback_m: float = 180.0) -> Vector2:
	var best := centre + Vector2(0.0, fallback_m)
	var best_d := -1.0
	for r in roads:
		var poly: PackedVector2Array = PackedVector2Array((r as Dictionary).get("points", PackedVector2Array()))
		if poly.size() < 2:
			continue
		for p in [poly[0], poly[poly.size() - 1]]:
			var d := (p as Vector2).distance_to(centre)
			if d > best_d:
				best_d = d
				best = p
	return best


# --- helpers -------------------------------------------------------------------

## Nearest point on a polyline: {s (arc length), d (distance), p}.
static func _nearest_on(poly: PackedVector2Array, q: Vector2) -> Dictionary:
	var best := {"s": 0.0, "d": INF, "p": poly[0]}
	var acc := 0.0
	for i in poly.size() - 1:
		var a := poly[i]
		var b := poly[i + 1]
		var ab := b - a
		var L := ab.length()
		var u := clampf((q - a).dot(ab) / maxf(L * L, 1e-9), 0.0, 1.0)
		var p := a + ab * u
		var d := p.distance_to(q)
		if d < float(best["d"]):
			best = {"s": acc + L * u, "d": d, "p": p}
		acc += L
	return best


## The polyline between arc lengths sa and sb, in that direction.
static func _sub_polyline(poly: PackedVector2Array, sa: float, sb: float) -> Array:
	var out: Array = [_point_at(poly, sa)]
	var acc := 0.0
	var verts: Array = []
	for i in poly.size():
		if i > 0:
			acc += poly[i - 1].distance_to(poly[i])
		verts.append([acc, poly[i]])
	if sb >= sa:
		for v in verts:
			if float(v[0]) > sa and float(v[0]) < sb:
				out.append(v[1])
	else:
		for k in range(verts.size() - 1, -1, -1):
			var v2: Array = verts[k]
			if float(v2[0]) < sa and float(v2[0]) > sb:
				out.append(v2[1])
	out.append(_point_at(poly, sb))
	return out


static func _point_at(poly: PackedVector2Array, s: float) -> Vector2:
	var acc := 0.0
	for i in poly.size() - 1:
		var L := poly[i].distance_to(poly[i + 1])
		if acc + L >= s:
			return poly[i].lerp(poly[i + 1], clampf((s - acc) / maxf(L, 1e-9), 0.0, 1.0))
		acc += L
	return poly[poly.size() - 1]


## Centripetal Catmull-Rom through the control points, sampled ~SAMPLE_M.
static func _densify(ctrl: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	var n := ctrl.size()
	for i in n - 1:
		var p1: Vector2 = ctrl[i]
		var p2: Vector2 = ctrl[i + 1]
		var p0: Vector2 = ctrl[i - 1] if i > 0 else p1 + (p1 - p2)
		var p3: Vector2 = ctrl[i + 2] if i + 2 < n else p2 + (p2 - p1)
		var seg := p1.distance_to(p2)
		var steps := maxi(int(ceil(seg / SAMPLE_M)), 1)
		for k in steps:
			out.append(_cr(p0, p1, p2, p3, float(k) / float(steps)))
	out.append(ctrl[n - 1])
	return out


static func _cr(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, t: float) -> Vector2:
	# Barry–Goldman form with alpha 0.5 (centripetal: no cusps or loops).
	var t0 := 0.0
	var t1 := t0 + pow(maxf(p0.distance_to(p1), 1e-4), 0.5)
	var t2 := t1 + pow(maxf(p1.distance_to(p2), 1e-4), 0.5)
	var t3 := t2 + pow(maxf(p2.distance_to(p3), 1e-4), 0.5)
	var tt := lerpf(t1, t2, t)
	var a1 := p0 * ((t1 - tt) / (t1 - t0)) + p1 * ((tt - t0) / (t1 - t0))
	var a2 := p1 * ((t2 - tt) / (t2 - t1)) + p2 * ((tt - t1) / (t2 - t1))
	var a3 := p2 * ((t3 - tt) / (t3 - t2)) + p3 * ((tt - t2) / (t3 - t2))
	var b1 := a1 * ((t2 - tt) / (t2 - t0)) + a2 * ((tt - t0) / (t2 - t0))
	var b2 := a2 * ((t3 - tt) / (t3 - t1)) + a3 * ((tt - t1) / (t3 - t1))
	return b1 * ((t2 - tt) / (t2 - t1)) + b2 * ((tt - t1) / (t2 - t1))


static func _circumradius(a: Vector2, b: Vector2, c: Vector2) -> float:
	var ab := a.distance_to(b)
	var bc := b.distance_to(c)
	var ca := c.distance_to(a)
	var cross := absf((b - a).cross(c - a))
	if cross < 1e-6:
		return 1e6
	return ab * bc * ca / (2.0 * cross)
