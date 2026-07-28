class_name NpcMetabolism
extends RefCounted

## Metabolic cost of walking (POPULATION_PLAN.md Tier 3d) — the number that
## turns a site layout into a measurable design variable.
##
## MODEL: the ACSM walking equation (ACSM's *Guidelines for Exercise Testing
## and Prescription*), the standard grade-adjusted estimate of walking oxygen
## cost:
##
##   VO2 [mL/kg/min] = 3.5 + 0.1*S + 1.8*S*G      S = m/min, G = fractional grade
##   kcal/min        = VO2 * mass_kg / 1000 * 5   (~5 kcal per litre of O2)
##
## Valid for roughly 50-100 m/min, which brackets the project's 1.3 m/s
## (78 m/min) walking speed.
##
## Sanity check at that speed, 70 kg, flat: VO2 = 3.5 + 7.8 = 11.3 ->
## 3.96 kcal/min -> ~51 kcal/km, matching the accepted ~50-60 kcal/km for a
## 70 kg adult. The selftest pins this.
##
## GRADE is clamped at zero for downhill: the ACSM equation is not valid for
## negative grades (descending costs less than level walking, but not
## linearly, and never less than the resting term). Treating a descent as
## free-but-not-negative is the conservative reading.
##
## For chores that involve carrying, the load-bearing upgrade is Pandolf,
## Givoni & Goldman (1977), "Predicting energy expenditure with loads while
## standing or walking very slowly" — not modelled here because nothing in
## the sim carries mass yet.

## Resting term of the ACSM equation (1 MET).
const RESTING_VO2 := 3.5
const VO2_SPEED_COEF := 0.1
const VO2_GRADE_COEF := 1.8
## Energy released per litre of oxygen consumed.
const KCAL_PER_L_O2 := 5.0
const DEFAULT_MASS_KG := 70.0
## A rough adult daily intake, used only to express walking as a share of the
## day's energy budget.
const DAILY_BASELINE_KCAL := 2000.0


## Oxygen cost of walking at `speed_m_per_min` on fractional grade `grade`.
static func vo2(speed_m_per_min: float, grade: float) -> float:
	var s := maxf(speed_m_per_min, 0.0)
	var g := maxf(grade, 0.0)   # see the header: no credit for descending
	return RESTING_VO2 + VO2_SPEED_COEF * s + VO2_GRADE_COEF * s * g


static func kcal_per_min(speed_m_per_min: float, grade: float,
		mass_kg: float = DEFAULT_MASS_KG) -> float:
	return vo2(speed_m_per_min, grade) * mass_kg / 1000.0 * KCAL_PER_L_O2


## Gross kcal for one walked segment: `dist_m` covered with `climb_m` of
## ascent, at `speed_mps`. Gross means it includes the resting term — that is
## what "calories burned while walking" means; subtract resting_kcal() for the
## marginal cost of the walking itself.
static func walk_kcal(dist_m: float, climb_m: float, speed_mps: float,
		mass_kg: float = DEFAULT_MASS_KG) -> float:
	if dist_m <= 0.0 or speed_mps <= 0.0:
		return 0.0
	var speed_m_min := speed_mps * 60.0
	var grade := climb_m / dist_m if dist_m > 0.0 else 0.0
	var minutes := dist_m / speed_m_min
	return kcal_per_min(speed_m_min, grade, mass_kg) * minutes


## What the same span of time would have cost sitting still.
static func resting_kcal(minutes: float, mass_kg: float = DEFAULT_MASS_KG) -> float:
	return RESTING_VO2 * mass_kg / 1000.0 * KCAL_PER_L_O2 * maxf(minutes, 0.0)


## Marginal cost of having walked, i.e. above what resting would have cost.
## This is the honest "what the layout costs you" figure.
static func net_walk_kcal(dist_m: float, climb_m: float, speed_mps: float,
		mass_kg: float = DEFAULT_MASS_KG) -> float:
	if dist_m <= 0.0 or speed_mps <= 0.0:
		return 0.0
	var minutes := dist_m / (speed_mps * 60.0)
	return maxf(walk_kcal(dist_m, climb_m, speed_mps, mass_kg)
			- resting_kcal(minutes, mass_kg), 0.0)


## Walking as a share of a day's energy budget — the spatial-efficiency
## headline. A camp costing 8% of everyone's day just getting to water is a
## bad plan, and this is what says so.
static func overhead_fraction(walk_kcal_day: float,
		baseline_kcal: float = DAILY_BASELINE_KCAL) -> float:
	if baseline_kcal <= 0.0:
		return 0.0
	return clampf(walk_kcal_day / baseline_kcal, 0.0, 1.0)


## Player-facing verdict on a site's walkability.
static func efficiency_label(walk_kcal_day: float) -> String:
	var pct := overhead_fraction(walk_kcal_day) * 100.0
	if pct < 1.5:
		return "Compact"
	if pct < 3.0:
		return "Comfortable"
	if pct < 5.0:
		return "Spread out"
	if pct < 8.0:
		return "Tiring"
	return "Punishing"
