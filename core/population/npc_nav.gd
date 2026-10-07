class_name NpcNav
extends RefCounted

## v1 NPC movement: straight-line walk in world XZ with graceful degradation
## at high time scales — when one tick's travel covers the remaining distance
## (always true at ~450x realtime), the agent snaps to the destination and
## starts its activity. Movement is cosmetic; consumption is rate-based in
## sim-hours, so mass stays exact regardless of time scale.
## Obstacle avoidance is deferred behind this API (a coarse walkable-grid A*
## in the spirit of ConduitAStar can slot in later without touching agents).

## Typical unhurried walking speed (Bohannon 1997, comfortable gait ~1.3 m/s).
const WALK_SPEED_MPS := 1.3


static func advance(pos: Vector2, dest: Vector2, dt_hours: float) -> Vector2:
	var step_m := WALK_SPEED_MPS * maxf(dt_hours, 0.0) * 3600.0
	var delta := dest - pos
	if delta.length() <= step_m:
		return dest
	return pos + delta.normalized() * step_m


static func travel_hours(from_pos: Vector2, to_pos: Vector2) -> float:
	return (to_pos - from_pos).length() / (WALK_SPEED_MPS * 3600.0)


static func hours_for_distance(metres: float) -> float:
	return maxf(metres, 0.0) / (WALK_SPEED_MPS * 3600.0)


## Follow a planned route, consuming waypoints as they are reached. Returns
## `[new_pos, new_index, metres_walked]`. The teleport degradation of the
## straight-line path is preserved: at high time scale one step can swallow
## the whole route, and the agent simply arrives.
static func advance_path(pos: Vector2, path: PackedVector2Array, idx: int,
		dt_hours: float) -> Array:
	var budget := WALK_SPEED_MPS * maxf(dt_hours, 0.0) * 3600.0
	var walked := 0.0
	var p := pos
	var i := idx
	while i < path.size() and budget > 0.0:
		var target: Vector2 = path[i]
		var d := p.distance_to(target)
		if d <= budget:
			budget -= d
			walked += d
			p = target
			i += 1
		else:
			var move := (target - p).normalized() * budget
			p += move
			walked += budget
			budget = 0.0
	return [p, i, walked]


## Metres left along `path` from `pos` at waypoint `idx`.
## A straight walk from `a` to `b` that would cut through one of `circles`
## ([{centre: Vector2, r: float}] — the fire perimeters) gets ONE waypoint
## pushed out to the circle's edge plus `margin`, on the side the line already
## favours. Returns [] when the line is clear (or an endpoint is inside, which
## is a seat problem, not a walking one). Used only where the A* grid is not
## available: the grid blocks the circle itself.
static func detour(a: Vector2, b: Vector2, circles: Array, margin: float = 1.5) -> PackedVector2Array:
	var ab := b - a
	var len2 := ab.length_squared()
	if len2 <= 1e-6:
		return PackedVector2Array()
	for c in circles:
		var cd: Dictionary = c
		var centre: Vector2 = cd.get("centre", Vector2.INF)
		var r := float(cd.get("r", 0.0))
		if r <= 0.0 or centre == Vector2.INF:
			continue
		if a.distance_to(centre) <= r or b.distance_to(centre) <= r:
			continue
		var t := clampf((centre - a).dot(ab) / len2, 0.0, 1.0)
		var closest := a + ab * t
		var d := closest.distance_to(centre)
		if d >= r or t <= 0.0 or t >= 1.0:
			continue
		# Walk the arc round the perimeter from a's bearing to b's, the short
		# way, in steps of at most 60 degrees — one waypoint off the near side
		# still cut the circle on its second leg when b lay across it.
		var big := r + margin
		var ta := (a - centre).angle()
		var tb := (b - centre).angle()
		var delta := wrapf(tb - ta, -PI, PI)
		if absf(delta) < 1e-4:
			var out_dir := (closest - centre).normalized() if d > 1e-4 else Vector2(-ab.y, ab.x).normalized()
			return PackedVector2Array([centre + out_dir * big, b])
		var n := maxi(int(ceil(absf(delta) / (PI / 3.0))), 1)
		var out := PackedVector2Array()
		for k in range(0, n + 1):
			var th := ta + delta * float(k) / float(n)
			out.append(centre + Vector2(cos(th), sin(th)) * big)
		out.append(b)
		return out
	return PackedVector2Array()


static func path_remaining_m(pos: Vector2, path: PackedVector2Array, idx: int) -> float:
	if idx >= path.size():
		return 0.0
	var total := pos.distance_to(path[idx])
	for i in range(idx + 1, path.size()):
		total += path[i - 1].distance_to(path[i])
	return total
