class_name HydroSupply
extends RefCounted

## Hydrology of a tapped water SOURCE — a spring, creek or diverted stream feeding
## a penstock. Deliberately separate from PeltonPhysics: this answers "how much
## water is running today", the turbine physics answers "what can the machine do
## with it", and this half is also called straight from the inspector, so it must
## not drag turbine concepts in.
##
## Pure static + deterministic so it selftests offline.
##
## The rain term is authored in the unit a micro-hydro siter actually thinks in —
## litres per second per TENTH OF AN INCH of rainfall per hour — and converted to
## the engine's metric mm/h here, at one choke point.
##
## Sources:
##  - Rain unit: 0.1 in = 2.54 mm exactly (international inch, 25.4 mm).
##  - Recession: the standard single-linear-reservoir baseflow model, Q(t) =
##    Q0·e^(−t/τ) toward a new equilibrium — Maillet (1905), still the textbook
##    first-order form for spring/baseflow decay.

## 0.1 inch of rain, in millimetres. The whole reason the user-facing coefficient
## reads in tenths of an inch per hour rather than mm/h.
const MM_PER_TENTH_INCH := 2.54

const DEFAULT_BASE_FLOW_LPS := 1.0
const DEFAULT_RAIN_LPS_PER_TENTH_IN_H := 0.5


## Instantaneous (unlagged) supply at a stream intake, L/s.
##   Q = base_flow_lps + rain_lps_per_tenth_in_h × (rain_mmh / 2.54)
## capped by max_flow_lps when that is > 0 (a channel or diversion box can only
## pass so much however hard it rains).
static func intake_supply_lps(specs: Dictionary, rain_mmh: float) -> float:
	var base := maxf(float(specs.get("base_flow_lps", DEFAULT_BASE_FLOW_LPS)), 0.0)
	var k := maxf(float(specs.get("rain_lps_per_tenth_in_h",
			DEFAULT_RAIN_LPS_PER_TENTH_IN_H)), 0.0)
	var rain := maxf(rain_mmh, 0.0)
	if is_nan(rain):
		rain = 0.0
	var q := base + k * (rain / MM_PER_TENTH_INCH)
	var cap := float(specs.get("max_flow_lps", 0.0))
	if cap > 0.0:
		q = minf(q, cap)
	return maxf(q, 0.0)


## The rain CONTRIBUTION alone (L/s) — what the inspector shows so a player can
## see the storm response separately from the dry-weather spring.
static func rain_term_lps(specs: Dictionary, rain_mmh: float) -> float:
	var k := maxf(float(specs.get("rain_lps_per_tenth_in_h",
			DEFAULT_RAIN_LPS_PER_TENTH_IN_H)), 0.0)
	var rain := maxf(rain_mmh, 0.0)
	if is_nan(rain):
		rain = 0.0
	return k * (rain / MM_PER_TENTH_INCH)


## Per-month supply (L/s) from a 12-entry array of MEAN rainfall rates (mm/h).
##
## Exact for the uncapped case: intake_supply_lps is linear in rain rate, so the
## supply at the mean rain rate IS the mean supply. Where `max_flow_lps` bites it
## is optimistic (mean-then-cap >= cap-then-mean), which is the same
## representative-year simplification the rest of the hydro estimator already
## makes with monthly_flow_multipliers.
static func monthly_supply_lps(specs: Dictionary,
		monthly_rain_mmh: Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if monthly_rain_mmh.size() != 12:
		return out
	out.resize(12)
	for m in 12:
		out[m] = intake_supply_lps(specs, float(monthly_rain_mmh[m]))
	return out


## First-order recession toward `target` over `dt_h` sim-hours.
##
## Uses 1 − exp(−dt/τ), which is EXACT for a step input at any dt. A naive
## lerp(dt/τ) overshoots — and this runs at whatever tick the world clock hands
## it, which at high time_scale is routinely a multi-hour step, so the naive form
## would oscillate instead of settling.
##
## τ <= 0 means no lag (the default): the supply tracks the rain instantly, which
## keeps the whole engine scrub-safe the way the rest of the sim is.
static func recess(prev_lps: float, target_lps: float, dt_h: float,
		tau_h: float) -> float:
	if tau_h <= 0.0 or dt_h <= 0.0 or is_nan(prev_lps):
		return maxf(target_lps, 0.0)
	var k := 1.0 - exp(-dt_h / tau_h)
	return maxf(lerpf(prev_lps, maxf(target_lps, 0.0), clampf(k, 0.0, 1.0)), 0.0)


## Defaults stamped onto a newly minted stream intake (and back-filled onto older
## ones by the flow engine's migration). A brand-new intake must supply SOMETHING
## or the first thing a player sees after routing a penstock is still 0 W.
static func default_intake_specs() -> Dictionary:
	return {
		"base_flow_lps": DEFAULT_BASE_FLOW_LPS,
		"rain_lps_per_tenth_in_h": DEFAULT_RAIN_LPS_PER_TENTH_IN_H,
		"max_flow_lps": 0.0,
		"recession_tau_h": 0.0,
	}
