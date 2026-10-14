class_name NpcMorale
extends RefCounted

## Morale model for simulated people — the scale, worst to best:
##   FUCK THIS!!! · Fuck You · Fuck Me · Fuck It · Fuck Maybe · Fuck It!
## and above the top band the PEAK EXPERIENCE state, FUCK YES!!! (NpcPeak —
## not a morale band: it is reached together, not alone).
## Pure static math (no scene, no state) so the agent sim, the inspector, the
## Site Plan and the crosshair all read the same numbers, and so the whole
## thing is trivially selftestable.
##
## Design invariants (POPULATION_PLAN.md):
##  * Morale is easier to lose than to regain.
##  * Meeting needs alone cannot exceed BASELINE_CEILING — the rest must be
##    earned through enrichment.
##  * A need that is BLOCKED (starved supply / no tagged space) hurts about
##    twice what the same discomfort costs while someone simply walks to a
##    working facility. Broken infrastructure is the thing that destroys a
##    community, not busy people.

## Band floors, highest first. Index 0 = best.
const BANDS: Array = [
	{"min": 0.85, "label": "Fuck It!", "color": Color(0.35, 0.86, 0.52)},
	{"min": 0.70, "label": "Fuck Maybe", "color": Color(0.58, 0.84, 0.44)},
	{"min": 0.50, "label": "Fuck It", "color": Color(0.90, 0.82, 0.38)},
	{"min": 0.30, "label": "Fuck Me", "color": Color(0.94, 0.62, 0.30)},
	{"min": 0.12, "label": "Fuck You", "color": Color(0.93, 0.40, 0.30)},
	{"min": 0.00, "label": "FUCK THIS!!!", "color": Color(0.85, 0.22, 0.28)},
]

## Needs that damage morale when unmet. Hygiene and enrichment are comfort
## needs — they never apply critical pressure (enrichment acts on the ceiling).
const CRITICAL_NEEDS: Array = ["sleep", "thirst", "hunger", "bladder"]

## Discomfort below this is ordinary life and costs nothing.
const PAIN_THRESHOLD := 0.75

## Morale lost per sim-hour at need level 1.0, unblocked.
const WEIGHT: Dictionary = {
	"sleep": 0.10,
	"thirst": 0.14,
	"hunger": 0.10,
	"bladder": 0.06,
}

const BLOCKED_MULT := 2.0
const RECOVERY_PER_H := 0.035
const BASELINE_CEILING := 0.75
## Drift back down when enrichment lapses and morale sits above its ceiling.
const CEILING_DECAY_PER_H := 0.02
const START_MORALE := 0.70

## Departure model.
const QUIT_THRESHOLD := 0.12
const QUIT_PRESSURE_H := 1.0        # (threshold-morale)·hours to accumulate
const QUIT_DECAY_PER_H := 0.15      # pressure bleeds off once recovered
## Seeing someone leave is demoralising (scaled by the share of the roster).
const DEPARTURE_SHOCK := 0.04

## Productivity multiplier from morale — low morale slows the very work that
## would raise it (the cascade), high morale speeds it up (the buffer).
const PRODUCTIVITY_MIN := 0.55
const PRODUCTIVITY_MAX := 1.15


static func band(morale: float) -> int:
	var m := clampf(morale, 0.0, 1.0)
	for i in BANDS.size():
		if m >= float((BANDS[i] as Dictionary)["min"]):
			return i
	return BANDS.size() - 1


static func label(morale: float) -> String:
	return str((BANDS[band(morale)] as Dictionary)["label"])


static func color(morale: float) -> Color:
	return (BANDS[band(morale)] as Dictionary)["color"] as Color


## Morale lost per sim-hour from unmet critical needs. `blocked` maps need ->
## true for needs the agent currently cannot act on.
static func pressure(needs: Dictionary, blocked: Dictionary = {}) -> float:
	var total := 0.0
	var span := 1.0 - PAIN_THRESHOLD
	for need in CRITICAL_NEEDS:
		var level := clampf(float(needs.get(need, 0.0)), 0.0, 1.0)
		var over := level - PAIN_THRESHOLD
		if over <= 0.0:
			continue
		# Superlinear: real deprivation dominates ordinary discomfort.
		var norm := (over * over) / (span * span)
		var w := float(WEIGHT.get(need, 0.0))
		if bool(blocked.get(need, false)):
			w *= BLOCKED_MULT
		total += w * norm
	return total


## Highest morale reachable given how enriched this person is. `enrichment` is
## the NEED level (0 = richly enriched, 1 = starved of it), so a community that
## never gathers is capped at BASELINE_CEILING.
static func ceiling(enrichment_need: float) -> float:
	var e := clampf(enrichment_need, 0.0, 1.0)
	return BASELINE_CEILING + (1.0 - BASELINE_CEILING) * (1.0 - e)


## d(morale)/d(sim-hour). `exposure` is extra drain from working outdoors in
## hostile weather (see NpcWeatherGate).
static func delta_per_hour(morale: float, needs: Dictionary,
		blocked: Dictionary = {}, enrichment_need: float = 1.0,
		exposure: float = 0.0) -> float:
	var p := pressure(needs, blocked)
	var cap := ceiling(enrichment_need)
	var m := clampf(morale, 0.0, 1.0)
	if m > cap:
		# Above the earned ceiling: sink toward it (plus any live pressure).
		return -CEILING_DECAY_PER_H - p - exposure
	var gain := RECOVERY_PER_H if m < cap else 0.0
	return gain - p - exposure


## Integrate one step, clamped so recovery never overshoots the earned ceiling.
static func step(morale: float, dt_hours: float, needs: Dictionary,
		blocked: Dictionary = {}, enrichment_need: float = 1.0,
		exposure: float = 0.0) -> float:
	if dt_hours <= 0.0:
		return clampf(morale, 0.0, 1.0)
	var d := delta_per_hour(morale, needs, blocked, enrichment_need, exposure)
	var next := morale + d * dt_hours
	if d > 0.0:
		next = minf(next, ceiling(enrichment_need))
	return clampf(next, 0.0, 1.0)


## Quit pressure after one step. Accrues only below QUIT_THRESHOLD, and bleeds
## off once someone is pulled back — so rescuing a person costs real sim time
## but is possible.
static func step_quit_pressure(pressure_h: float, morale: float, dt_hours: float) -> float:
	if dt_hours <= 0.0:
		return maxf(pressure_h, 0.0)
	if morale < QUIT_THRESHOLD:
		return maxf(pressure_h + (QUIT_THRESHOLD - morale) * dt_hours, 0.0)
	return maxf(pressure_h - QUIT_DECAY_PER_H * dt_hours, 0.0)


static func wants_to_leave(pressure_h: float) -> bool:
	return pressure_h >= QUIT_PRESSURE_H


static func productivity(morale: float) -> float:
	return lerpf(PRODUCTIVITY_MIN, PRODUCTIVITY_MAX, clampf(morale, 0.0, 1.0))
