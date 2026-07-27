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
