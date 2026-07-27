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
static func path_remaining_m(pos: Vector2, path: PackedVector2Array, idx: int) -> float:
	if idx >= path.size():
		return 0.0
	var total := pos.distance_to(path[idx])
	for i in range(idx + 1, path.size()):
		total += path[i - 1].distance_to(path[i])
	return total
