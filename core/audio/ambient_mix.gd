class_name AmbientMix
extends RefCounted

## The first-person ambient bed's MIX RULE — pure functions of what the world
## is doing, so core/audio/ambient_mix_selftest.gd can pin them offline.
## AmbientBed (the node) feeds them the live inputs and smooths the result.
##
## Four layers, each a 0..1 loudness:
##   wind    — WeatherService's 10 m wind speed. Beaufort: nothing to hear
##             under ~1 m/s, a full bed by near gale (14 m/s).
##   rain    — rain_rate_mmh through the met classes NpcComfort already uses
##             (light < 2.5 mm/h, moderate to 7.6, heavy beyond).
##   stream  — the nearest StreamNetwork feature's Manning velocity, falling
##             off with distance (full within 6 m, gone by 60 m).
##   birds   — DaylightModel's skylight (none at night, the chorus from civil
##             dawn, quieter under a high sun) × how much forest stands round
##             the listener, hushed by rain and wind.
## The MASTER is the player's volume (Settings → NPCs, beside stage music),
## zero while the sim is paused (SimFxRate.is_paused — a frozen world is a
## silent one, like the fire and the lights) and zero away from first person
## (the graph, the settlement view, the window wall have their own sound).

const WIND_START_MS := 1.0
const WIND_FULL_MS := 14.0
const WIND_CURVE := 0.7          # loudness grows faster than linearly at first

const RAIN_LIGHT_MMH := 2.5
const RAIN_HEAVY_MMH := 7.6
const RAIN_FULL_MMH := 30.0
const RAIN_LIGHT_LEVEL := 0.4
const RAIN_HEAVY_LEVEL := 0.75

const STREAM_NEAR_M := 6.0
const STREAM_FAR_M := 60.0
const STREAM_V_MIN_MS := 0.15    # a trickle is silent
const STREAM_V_FULL_MS := 1.5

const BIRD_DAWN_LO := 0.15       # skylight where the chorus starts (civil dawn)
const BIRD_DAWN_HI := 0.5
const BIRD_MIDDAY_LO := 0.6
const BIRD_MIDDAY_LEVEL := 0.6   # quieter under a high sun than at dawn
const BIRD_FOREST_LO := 0.05
const BIRD_FOREST_HI := 0.6
const BIRD_RAIN_HUSH := 0.8
const BIRD_WIND_HUSH := 0.5
const BIRD_CHIRPS_PER_S := 1.6   # at full birds level

const SMOOTH_TAU_S := 0.6        # the node's ease toward a new target

## Forest density: trees within this radius of the listener, against a
## closed canopy's count (≈ 0.025 trees / m², 7 m spacing).
const FOREST_RADIUS_M := 30.0
const FOREST_FULL_TREES_PER_M2 := 0.025


static func wind_level(wind_ms: float) -> float:
	var x := clampf((wind_ms - WIND_START_MS) / (WIND_FULL_MS - WIND_START_MS), 0.0, 1.0)
	return pow(x, WIND_CURVE)


## Piecewise linear through the met classes: continuous, monotonic.
static func rain_level(rain_mmh: float) -> float:
	var r := maxf(rain_mmh, 0.0)
	if r <= 0.0:
		return 0.0
	if r < RAIN_LIGHT_MMH:
		return RAIN_LIGHT_LEVEL * r / RAIN_LIGHT_MMH
	if r < RAIN_HEAVY_MMH:
		return lerpf(RAIN_LIGHT_LEVEL, RAIN_HEAVY_LEVEL, (r - RAIN_LIGHT_MMH) / (RAIN_HEAVY_MMH - RAIN_LIGHT_MMH))
	return lerpf(RAIN_HEAVY_LEVEL, 1.0, clampf((r - RAIN_HEAVY_MMH) / (RAIN_FULL_MMH - RAIN_HEAVY_MMH), 0.0, 1.0))


static func stream_level(velocity_ms: float, dist_m: float) -> float:
	if dist_m < 0.0 or dist_m >= STREAM_FAR_M or velocity_ms <= STREAM_V_MIN_MS:
		return 0.0
	var loud := clampf((velocity_ms - STREAM_V_MIN_MS) / (STREAM_V_FULL_MS - STREAM_V_MIN_MS), 0.0, 1.0)
	var fall := 1.0
	if dist_m > STREAM_NEAR_M:
		var t := (dist_m - STREAM_NEAR_M) / (STREAM_FAR_M - STREAM_NEAR_M)
		fall = (1.0 - t) * (1.0 - t)
	return loud * fall


## `sun_sin_alt` = the sun direction's y; `forest` 0..1 from forest_density().
static func bird_level(sun_sin_alt: float, forest: float, rain_mmh: float = 0.0, wind_ms: float = 0.0) -> float:
	var sl := DaylightModel.sky_light(sun_sin_alt)
	var activity := smoothstep(BIRD_DAWN_LO, BIRD_DAWN_HI, sl) \
		* lerpf(1.0, BIRD_MIDDAY_LEVEL, smoothstep(BIRD_MIDDAY_LO, 1.0, sl))
	var trees := smoothstep(BIRD_FOREST_LO, BIRD_FOREST_HI, clampf(forest, 0.0, 1.0))
	var hush := (1.0 - BIRD_RAIN_HUSH * rain_level(rain_mmh)) * (1.0 - BIRD_WIND_HUSH * wind_level(wind_ms))
	return clampf(activity * trees * hush, 0.0, 1.0)


## 0..1 from a tree count inside FOREST_RADIUS_M.
static func forest_density(trees_within: int, radius_m: float = FOREST_RADIUS_M) -> float:
	var full := PI * radius_m * radius_m * FOREST_FULL_TREES_PER_M2
	return clampf(float(trees_within) / maxf(full, 1.0), 0.0, 1.0)


## The whole rule. Inputs (missing keys take the quiet default):
##   wind_ms, rain_mmh, stream_v_ms, stream_dist_m (-1 = no stream),
##   sun_sin_alt, forest (0..1), volume (0..1), paused, first_person.
## Returns {wind, rain, stream, birds, master, chirps_per_s}: the four
## layer GAINS (already × master) and the birdsong scheduler's rate.
static func levels(inputs: Dictionary) -> Dictionary:
	var wind_ms := float(inputs.get("wind_ms", 0.0))
	var rain_mmh := float(inputs.get("rain_mmh", 0.0))
	var master := clampf(float(inputs.get("volume", 1.0)), 0.0, 1.0)
	if bool(inputs.get("paused", false)) or not bool(inputs.get("first_person", true)):
		master = 0.0
	var wind := wind_level(wind_ms)
	var rain := rain_level(rain_mmh)
	var stream := stream_level(float(inputs.get("stream_v_ms", 0.0)), float(inputs.get("stream_dist_m", -1.0)))
	var birds := bird_level(float(inputs.get("sun_sin_alt", -1.0)), float(inputs.get("forest", 0.0)), rain_mmh, wind_ms)
	return {
		"wind": wind * master, "rain": rain * master, "stream": stream * master, "birds": birds * master,
		"master": master, "chirps_per_s": birds * BIRD_CHIRPS_PER_S * (1.0 if master > 0.0 else 0.0),
	}


## One ease step toward a target (exponential, dt-exact).
static func smooth(current: float, target: float, dt: float, tau: float = SMOOTH_TAU_S) -> float:
	if tau <= 0.0 or dt <= 0.0:
		return target
	return lerpf(target, current, exp(-dt / tau))


## A gain as the player's volume_db (−80 dB = silence; the floor keeps the
## log finite).
static func gain_to_db(gain: float) -> float:
	if gain <= 0.001:
		return -80.0
	return linear_to_db(clampf(gain, 0.0, 1.0))
