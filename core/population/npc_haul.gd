class_name NpcHaulModel
extends RefCounted
## Group hauling strategies — the first "emergent group behavior" primitive
## (PACKING_PLAN.md Phase 6 / the rules-not-avatars direction): the player
## states a GOAL (move U units from A to B with N people) and the group's
## strategy + throughput fall out of simple physical rules, not scripting.
##
## Two strategies, both from first principles:
##
## ROUND TRIP — each worker independently cycles: walk the route loaded,
## walk back empty, plus per-unit handling (pick up + set down).
##   cycle = L/v_loaded + L/v_empty + t_handle;  throughput = N / cycle.
##
## BUCKET BRIGADE — workers space themselves along the route and pass units
## down the chain. With spacing s = L/(N-1), each station's service time is
## the hand-off plus any shuttle its gap requires beyond arm reach:
##   leg = t_handoff + 2·max(s − reach, 0)/v_loaded
## and the pipeline's steady throughput is 1/leg (uniform stations — the
## slowest station governs; here they're identical). First unit pays the
## fill latency L/v before the pipeline is primed.
##
## The EMERGENT punchline the selftest pins: with enough people that spacing
## drops under arm reach, brigade throughput becomes 1/t_handoff —
## INDEPENDENT of route length. Few people on a long route → round trips
## win; a dense line → the brigade wins and distance stops mattering.
## Nobody writes that rule anywhere; it falls out of the two formulas.
##
## Pure static + deterministic, so group planning can be selftested offline
## and later driven live by the chore board (chore_hours from plan_eta).

const WALK_SPEED_MS := 1.3        # matches NpcAgent's nominal walk speed
const LOADED_FACTOR := 0.8        # carrying slows you down
const ARM_REACH_M := 1.5          # hand-to-hand pass distance
const T_HANDOFF_S := 2.5          # receive + turn + pass, per unit
const T_HANDLE_S := 8.0           # pick up + set down, per unit (round trip)
const MIN_BRIGADE_WORKERS := 3    # below this a "chain" is just two haulers


## Units per second for N independent round-trippers on an L-metre route.
static func round_trip_throughput(workers: int, length_m: float) -> float:
	if workers <= 0 or length_m < 0.0:
		return 0.0
	var cycle := length_m / (WALK_SPEED_MS * LOADED_FACTOR) \
		+ length_m / WALK_SPEED_MS + T_HANDLE_S
	return float(workers) / maxf(cycle, 0.001)


## Units per second for a brigade of N workers spanning L metres.
static func brigade_throughput(workers: int, length_m: float) -> float:
	if workers < MIN_BRIGADE_WORKERS or length_m <= 0.0:
		return 0.0
	var spacing := length_m / float(workers - 1)
	var shuttle := maxf(spacing - ARM_REACH_M, 0.0)
	var leg := T_HANDOFF_S + 2.0 * shuttle / (WALK_SPEED_MS * LOADED_FACTOR)
	return 1.0 / maxf(leg, 0.001)


## Pick the better strategy for the crew and answer with the full plan:
## {strategy, throughput_ups, eta_s, workers, length_m, units,
##  labor_hours (person-hours actually spent — workers × wall time)}.
static func best_plan(workers: int, length_m: float, units: int) -> Dictionary:
	var w := maxi(workers, 0)
	var u := maxi(units, 0)
	var rt := round_trip_throughput(w, length_m)
	var bg := brigade_throughput(w, length_m)
	var strategy := "brigade" if bg > rt else "round_trip"
	var ups := maxf(bg, rt)
	var eta := INF
	if u == 0:
		eta = 0.0
	elif ups > 0.0:
		eta = float(u) / ups
		if strategy == "brigade":
			# The pipeline pays a one-time fill latency for the first unit.
			eta += length_m / WALK_SPEED_MS
	return {
		"strategy": strategy,
		"throughput_ups": ups,
		"eta_s": eta,
		"workers": w,
		"length_m": length_m,
		"units": u,
		"labor_hours": (float(w) * eta / 3600.0) if eta != INF else INF,
	}


## One-person lift ceiling. 23 kg is the NIOSH lifting-equation load constant
## (RWL ceiling for a routine two-handed lift under ideal conditions —
## Waters et al. 1993); heavier loads are team lifts.
const SOLO_LIFT_KG := 23.0
## A team's usable capacity is LESS than the sum of its members — hands get in
## each other's way and the load is shared unevenly. ~0.85 per the two-person
## team-lift literature (Karwowski & Mital 1986 report 68-91% of summed
## individual capacity).
const TEAM_LIFT_EFF := 0.85
## Anything this long needs a hand on each end whatever it weighs — a 6 m beam
## is a two-person carry at any mass, purely to steer it.
const AWKWARD_LENGTH_M := 1.8
## More than four people cannot usefully reach one crate.
const MAX_CARRIERS := 4


## People needed to lift ONE object, from its mass and longest dimension.
## Unknown mass (<= 0, PackedSpec's -1 sentinel) reads as light — a solo
## carry, the long-standing behaviour.
static func carriers_for(mass_kg: float, long_m: float = 0.0) -> int:
	var n := 1
	if mass_kg > SOLO_LIFT_KG:
		n = 2
		while n < MAX_CARRIERS \
				and float(n) * SOLO_LIFT_KG * TEAM_LIFT_EFF < mass_kg:
			n += 1
	if long_m >= AWKWARD_LENGTH_M:
		n = maxi(n, 2)
	return clampi(n, 1, MAX_CARRIERS)


## Chore-board bridge: a NpcChoreBoard-shaped dict for a haul goal, sized by
## the plan's labor. The board's productivity/weather/morale scaling then
## applies on top exactly as it does for every other chore — group hauling
## slots into the existing rules-driven work system rather than beside it.
static func chore_spec(label: String, workers: int, length_m: float,
		units: int) -> Dictionary:
	var plan := best_plan(workers, length_m, units)
	var hours: float = plan["labor_hours"]
	return {
		"label": label,
		"chore_hours": (maxf(hours, 0.05) if hours != INF else 1.0),
		"exposure": "outdoor",
		"priority": 2,
		"repeat": "once",
		"haul_plan": plan,
	}
