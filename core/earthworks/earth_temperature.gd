class_name EarthTemperature
extends RefCounted

## How cool (or warm) a room in the ground stays: the soil temperature at the
## room's depth from the site's own year of air temperatures, and the room
## blended between that and the air by how much earth it is wrapped in. Pure.
##
## Ground: Kusuda & Achenbach (1965), the annual temperature wave damped and
## delayed with depth in a semi-infinite soil:
##   T(z, d) = Tm − As · e^(−z·k) · cos(2π/365 · (d − d0 − z/(2·k·365/(2π))))
## with k = √(π / (365 α)), Tm the annual mean air temperature, As half the
## swing of the monthly means and d0 the coldest day. α = 0.045 m²/day, a
## moist sandy / loamy soil (0.5e-6 m²/s; ASHRAE Handbook Fundamentals, soil
## thermal properties).
##
## The room: an ESTIMATE (no heat-balance model). The earth's share of the
## room's temperature rises with how deep the floor is and how many sides are
## bermed; the rest follows the day's air, already damped by the mass of the
## walls (a third of the swing round the month's mean reaches inside).

const ALPHA_M2_DAY := 0.045
const DAYS := 365.0
## How much of the outside swing round the month's mean gets inside.
const AIR_SWING_SHARE := 0.35


## The annual wave from 12 monthly means: {mean, amp, coldest_doy}, or {}
## with fewer than 12 finite months.
static func annual_wave(monthly_c: Array) -> Dictionary:
	if monthly_c.size() < 12:
		return {}
	var lo := INF
	var hi := -INF
	var sum := 0.0
	var cold_m := 0
	for m in 12:
		var v := float(monthly_c[m])
		if not is_finite(v):
			return {}
		sum += v
		if v < lo:
			lo = v
			cold_m = m
		hi = maxf(hi, v)
	return {"mean": sum / 12.0, "amp": (hi - lo) * 0.5, "coldest_doy": float(cold_m) * 30.44 + 15.0,
		"months": monthly_c.duplicate()}


## Soil temperature (°C) `depth_m` down on day of year `doy` (0-based).
static func ground_c(wave: Dictionary, depth_m: float, doy: float) -> float:
	if wave.is_empty():
		return NAN
	var z := maxf(depth_m, 0.0)
	var k := sqrt(PI / (DAYS * ALPHA_M2_DAY))
	var lag_days := z * k * DAYS / (2.0 * PI)
	return float(wave["mean"]) - float(wave["amp"]) * exp(-z * k) \
		* cos(2.0 * PI / DAYS * (doy - float(wave["coldest_doy"]) - lag_days))


## How deep the soil the room trades heat with sits (m): half the floor's
## depth plus half a metre, and BERM_TO_ROOF_M more when earth is piled to the
## roof (the room is then wrapped in metres of earth sideways, not only below).
const BERM_TO_ROOF_M := 2.0


static func coupling_depth_m(floor_depth_m: float, roof_cover: bool) -> float:
	return maxf(floor_depth_m, 0.0) * 0.5 + 0.5 + (BERM_TO_ROOF_M if roof_cover else 0.0)


## The earth's share of the room's temperature (0..0.85).
static func earth_share(floor_depth_m: float, bermed_sides: int, roof_cover: bool) -> float:
	var s := 0.25 + 0.15 * clampf(floor_depth_m, 0.0, 3.0) + 0.08 * float(clampi(bermed_sides, 0, 3))
	if roof_cover:
		s += 0.1
	return clampf(s, 0.0, 0.85)


## What it is inside (°C): the soil at the room's mid-height, blended with the
## damped air. `air_c` = outside now, `month_mean_c` = this month's mean.
static func indoor_c(wave: Dictionary, floor_depth_m: float, bermed_sides: int, roof_cover: bool,
		doy: float, air_c: float, month_mean_c: float) -> float:
	if wave.is_empty() or not is_finite(air_c):
		return air_c
	var g := ground_c(wave, coupling_depth_m(floor_depth_m, roof_cover), doy)
	var mm := month_mean_c if is_finite(month_mean_c) else air_c
	var inside_air := mm + (air_c - mm) * AIR_SWING_SHARE
	var share := earth_share(floor_depth_m, bermed_sides, roof_cover)
	return lerpf(inside_air, g, share)


## A structure record's indoor temperature at a moment: reads its earthworks
## (floor depth below grade, bermed sides). NAN without a wave.
static func for_spec(spec: Dictionary, wave: Dictionary, doy: float, air_c: float, month_mean_c: float) -> float:
	var s := StructureEarthworks.resolve(spec)
	var depth := float(s["sink_m"]) - float(s["floor_y"])
	var berm: Dictionary = s["berm"]
	var roof := false
	for side in berm.keys():
		if float((berm[side] as Dictionary).get("h", 0.0)) < 0.0:
			roof = true
	return indoor_c(wave, depth, berm.size(), roof, doy, air_c, month_mean_c)
