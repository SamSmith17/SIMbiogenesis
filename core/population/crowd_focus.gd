class_name CrowdFocus
extends RefCounted

## Which camps run the FULL population engine and which run the light crowd:
## focus follows the player. The camp you stand in (or the one you are
## watching / have selected) is promoted to full detail; everything else is
## light. Pure: hand it the camps and the viewer, get back a tier per camp.
##
## Two rules keep today's maps untouched: a site whose whole population fits
## the budget is FULL everywhere (no conversion ever happens, so a single-camp
## map behaves byte-identically), and a camp only changes tier when it has
## been on the other side of the line for `HYSTERESIS_H` — walking a lot
## boundary must not thrash the conversion.

const TIER_FULL := "full"
const TIER_LIGHT := "light"
## People the full engine may simulate at once (render tier scales it).
const MAX_FULL_PEOPLE := 150
## A camp whose anchor is within this of the viewer is a candidate.
const FULL_RADIUS_M := 120.0
const LEAVE_RADIUS_M := 160.0
## Sim-hours a camp must sit past the line before it converts.
const HYSTERESIS_H := 0.02
## The full engine is the per-substep cost (A* walks, separation, chores per
## agent) and a full-detail avatar is a blur at speed, so a FESTIVAL-scale
## site shrinks the full-tier budget as the clock speeds up. Sites that fit
## MAX_FULL_PEOPLE are untouched at any speed (no conversion, as before).
const TS_BUDGETS: Array = [[60.0, 150], [300.0, 90], [1000.0, 40], [INF, 16]]
## The full engine's own roster cap (NpcPopulationEngine.configure clamps
## here): a bigger camp can only ever run light.
const MAX_FULL_CAMP := 200


## Full-tier budget at a clock running `ts_mult` times realtime.
static func max_full_for(ts_mult: float) -> int:
	for b in TS_BUDGETS:
		if ts_mult <= float(b[0]):
			return int(b[1])
	return 16


## camps: [{id, home: Vector2, count}]; prev: {id: tier}; pending: {id: since_h}
## (mutated — the caller keeps it between calls). Returns {id: tier}.
static func decide(camps: Array, viewer: Vector2, watched_id: String, prev: Dictionary,
		pending: Dictionary, abs_h: float, max_full: int = MAX_FULL_PEOPLE,
		ts_mult: float = 0.0) -> Dictionary:
	var out := {}
	var total := 0
	for c in camps:
		total += int((c as Dictionary).get("count", 0))
	if total <= max_full:
		for c in camps:
			out[str((c as Dictionary)["id"])] = TIER_FULL
		pending.clear()
		return out
	if ts_mult > 0.0:
		# The speed table is written against the default budget; a player's
		# own budget (Settings -> NPCs) sheds by the same proportion.
		max_full = mini(max_full, int(round(float(max_full) * float(max_full_for(ts_mult))
			/ float(MAX_FULL_PEOPLE))))
	# Wanted set: the watched camp first, then by distance until the budget.
	var scored: Array = []
	for c in camps:
		var cd: Dictionary = c
		var id := str(cd["id"])
		var d := (cd.get("home", Vector2.ZERO) as Vector2).distance_to(viewer)
		var was_full := str(prev.get(id, TIER_LIGHT)) == TIER_FULL
		var reach := LEAVE_RADIUS_M if was_full else FULL_RADIUS_M
		var wants := id == watched_id or d <= reach
		scored.append([0.0 if id == watched_id else d, id, int(cd.get("count", 0)), wants])
	scored.sort_custom(func(a, b):
		if absf(float(a[0]) - float(b[0])) > 1e-6:
			return float(a[0]) < float(b[0])
		return str(a[1]) < str(b[1]))
	var budget := max_full
	var want_full: Dictionary = {}
	for s in scored:
		if not bool(s[3]):
			continue
		var n := int(s[2])
		if n > MAX_FULL_CAMP:
			continue   # the full engine cannot hold it — light, even watched
		if n <= budget or str(s[1]) == watched_id:
			want_full[str(s[1])] = true
			budget -= n
	for c in camps:
		var id := str((c as Dictionary)["id"])
		var cur := str(prev.get(id, TIER_LIGHT))
		var target := TIER_FULL if want_full.has(id) else TIER_LIGHT
		if target == cur:
			pending.erase(id)
			out[id] = cur
			continue
		if not pending.has(id):
			pending[id] = abs_h
		if abs_h - float(pending[id]) >= HYSTERESIS_H or not prev.has(id):
			out[id] = target
			pending.erase(id)
		else:
			out[id] = cur
	return out
