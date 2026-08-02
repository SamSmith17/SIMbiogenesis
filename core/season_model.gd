class_name SeasonModel
extends RefCounted

## Pure, deterministic seasonal phenology + snow-cover model.
##
## Two responsibilities, both stateless static functions:
##  1. season_signals(): photoperiod/phenology-driven 0..1 signals that the
##     vegetation shaders consume (leaf coverage, autumn colour, spring bud,
##     summer/winter warmth). Hemisphere-aware via latitude sign.
##  2. estimate_snow_cover(): weather-driven ground snow as a 0..1 coverage.
##     Prefers Open-Meteo's modelled `snow_depth`; falls back to a classic
##     degree-day accumulation/melt integration over a trailing window so that
##     generated/synthetic years (no snow_depth) still get a plausible snowpack.
##
## Kept free of scene/clock dependencies so it is trivially unit-testable and
## can be evaluated off the live clock (analemma stepping, batch render).

## Northern-hemisphere phenology calendar (day-of-year, non-leap reference).
const LEAF_OUT_START := 84.0     # ~Mar 25 — buds break
const LEAF_OUT_END := 135.0      # ~May 15 — full canopy
const LEAF_FULL_END := 300.0     # ~Oct 27 — canopy holds through summer
const LEAF_DROP_END := 332.0     # ~Nov 28 — bare for winter
const AUTUMN_START := 268.0      # ~Sep 25 — colour begins
const AUTUMN_PEAK := 298.0       # ~Oct 25 — peak colour
const AUTUMN_FADE_START := 315.0 # ~Nov 11
const AUTUMN_FADE_END := 335.0   # ~Dec 1 — leaves mostly down
const BUD_START := 84.0
const BUD_PEAK_END := 112.0
const BUD_FADE_END := 145.0
const SUMMER_SOLSTICE_DOY := 172.0
const YEAR_LEN := 365.25

## Grass height phenology (day-of-year, NH reference): grows through spring,
## stands tall through summer, cures/shortens through autumn, dormant/short in
## winter. Drives the grass shaders' runtime height scale.
const GRASS_GROW_START := 74.0    # ~Mar 15 — green-up begins
const GRASS_GROW_FULL := 160.0    # ~Jun 9 — full summer height
const GRASS_FADE_START := 280.0   # ~Oct 7 — growth slows, blades lay down
const GRASS_FADE_END := 330.0     # ~Nov 26 — dormant winter height

## Latitude seasonality damping (veg overhaul Phase 6). Photoperiod-driven
## phenology (autumn colour, deciduous leaf drop, winter dormancy) requires a
## real day-length swing: within the tropics (|lat| < ~15°) day length barely
## varies and broadleaf forests are evergreen — a mango at 5°N must never turn
## red in October. Ramp spans the subtropics, reaching full temperate
## seasonality by ~35° (roughly the poleward edge of tropical/subtropical
## evergreen forest biomes; Köppen A→C transition).
const SEASONALITY_LAT_MIN := 15.0  # below this: no autumn/leaf-drop/dormancy
const SEASONALITY_LAT_FULL := 35.0 # above this: full temperate seasonality

const _DAYS_BEFORE_MONTH := [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
const _DAYS_IN_MONTH := [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

## Degree-day snow model tuning.
const SNOW_T_THRESHOLD_C := 1.0   # precip below this falls as snow
const MELT_T_BASE_C := 0.0        # melt accrues above this
const MELT_RATE_MM_PER_DEG_DAY := 2.6
const SNOW_WINDOW_DAYS := 70       # trailing days integrated
const SNOW_SAMPLE_STRIDE_DAYS := 2 # sample every N days for cost
const SWE_FULL_MM := 22.0          # legacy reference (degree-day scale)
const COVER_DEPTH_M := 0.12        # depth for snow_amount = 1.0 (surface tint)
const SNOW_DEPTH_MAX_M := 2.5      # clamp for shaders / API spikes
## Fresh snow ~10:1 depth:SWE — 100 mm SWE ≈ 1 m pack.
const DEPTH_PER_SWE_MM := 0.01


## Map a 1-based day-of-year to its northern-hemisphere phenological equivalent,
## flipping by half a year in the southern hemisphere.
static func to_nh_doy(day_of_year: int, latitude: float) -> float:
	var doy := float(day_of_year)
	if latitude < 0.0:
		doy = fmod(doy + YEAR_LEN * 0.5, YEAR_LEN)
		if doy < 1.0:
			doy += YEAR_LEN
	return doy


## How strongly a site expresses temperate seasonality, 0..1 by latitude.
## 0 in the deep tropics (evergreen year-round), 1 from the mid-latitudes out.
static func seasonality_strength(latitude: float) -> float:
	return clampf(
		smoothstep(SEASONALITY_LAT_MIN, SEASONALITY_LAT_FULL, absf(latitude)),
		0.0, 1.0)


## All phenology signals for a date. Values are 0..1 unless noted.
##  leaf_coverage : 1 = full canopy, 0 = bare (drives deciduous leaf-loss)
##  autumn        : warm-colour blend strength (yellow/orange/red)
##  bud           : spring fresh-growth tint strength
##  summer        : warm-season lushness
##  winter        : cold-season dormancy (grass browning, general desaturation)
##  seasonality   : the latitude damping factor applied to the four above
static func season_signals(day_of_year: int, latitude: float) -> Dictionary:
	var doy := to_nh_doy(day_of_year, latitude)

	var leaf := _leaf_coverage(doy)
	var autumn := clampf(
		smoothstep(AUTUMN_START, AUTUMN_PEAK, doy)
		- smoothstep(AUTUMN_FADE_START, AUTUMN_FADE_END, doy),
		0.0, 1.0)
	var bud := clampf(
		smoothstep(BUD_START, BUD_PEAK_END, doy)
		- smoothstep(BUD_PEAK_END, BUD_FADE_END, doy),
		0.0, 1.0)

	var warmth := cos(TAU * (doy - SUMMER_SOLSTICE_DOY) / YEAR_LEN) # +1 summer, -1 winter
	var summer := clampf(smoothstep(0.15, 0.85, warmth), 0.0, 1.0)
	var winter := clampf(smoothstep(0.10, 0.80, -warmth), 0.0, 1.0)

	# Grass height envelope: 0 = dormant/mown-short, 1 = full seasonal height.
	var grass_growth := clampf(
		smoothstep(GRASS_GROW_START, GRASS_GROW_FULL, doy)
		- smoothstep(GRASS_FADE_START, GRASS_FADE_END, doy),
		0.0, 1.0)

	# Latitude damping: blend every seasonal signal toward its evergreen,
	# always-growing tropical value. Applied here rather than in the shaders so
	# growth, particles and the shaders all agree on one number.
	var season := seasonality_strength(latitude)
	if season < 1.0:
		leaf = lerpf(1.0, leaf, season)
		autumn = lerpf(0.0, autumn, season)
		bud = lerpf(0.0, bud, season)
		winter = lerpf(0.0, winter, season)
		summer = lerpf(1.0, summer, season)
		grass_growth = lerpf(1.0, grass_growth, season)

	return {
		"leaf_coverage": leaf,
		"autumn": autumn,
		"bud": bud,
		"summer": summer,
		"winter": winter,
		"grass_growth": grass_growth,
		"seasonality": season,
	}


static func _leaf_coverage(doy: float) -> float:
	if doy < LEAF_OUT_START:
		return 0.0
	if doy < LEAF_OUT_END:
		return smoothstep(LEAF_OUT_START, LEAF_OUT_END, doy)
	if doy < LEAF_FULL_END:
		return 1.0
	if doy < LEAF_DROP_END:
		return 1.0 - smoothstep(LEAF_FULL_END, LEAF_DROP_END, doy)
	return 0.0


## Estimate snowpack depth on the ground in metres. Prefers Open-Meteo `snow_depth`;
## otherwise integrates degree-day SWE over a trailing window and converts to depth.
static func estimate_snow_depth_m(ws: Object, month: int, day: int, hour: float, latitude: float) -> float:
	if ws != null and ws.has_method("has_snow_data") and bool(ws.call("has_snow_data", month, day, hour)):
		var depth := float(ws.call("snow_depth_m", month, day, hour))
		if is_finite(depth):
			return clampf(maxf(depth, 0.0), 0.0, SNOW_DEPTH_MAX_M)

	if ws == null or not ws.has_method("temperature_c"):
		return 0.0

	var doy_now: int = int(_DAYS_BEFORE_MONTH[clampi(month, 1, 12) - 1]) + clampi(day, 1, 31)
	var swe := 0.0 # snow water equivalent, mm
	var start: int = doy_now - SNOW_WINDOW_DAYS
	var d: int = start
	while d <= doy_now:
		var md := _doy_to_month_day(d)
		var t := float(ws.call("temperature_c", md.x, md.y, 12.0))
		if not is_finite(t):
			d += SNOW_SAMPLE_STRIDE_DAYS
			continue
		var precip_mm := 0.0
		if ws.has_method("rain_24h_mm"):
			var p := float(ws.call("rain_24h_mm", md.x, md.y, 12.0))
			if is_finite(p):
				precip_mm = maxf(p, 0.0)
		var span := float(SNOW_SAMPLE_STRIDE_DAYS)
		if t <= SNOW_T_THRESHOLD_C:
			swe += precip_mm
		else:
			swe -= MELT_RATE_MM_PER_DEG_DAY * maxf(t - MELT_T_BASE_C, 0.0) * span
		swe = maxf(swe, 0.0)
		d += SNOW_SAMPLE_STRIDE_DAYS

	var depth_m := swe * DEPTH_PER_SWE_MM
	return clampf(depth_m, 0.0, SNOW_DEPTH_MAX_M)


## Coldest-season sampling window for the winter-minimum estimate (Phase 6):
## mid-December through mid-February in the northern hemisphere, flipped south.
const WINTER_MIN_CENTER_DOY := 15.0   # ~Jan 15
const WINTER_MIN_HALF_WINDOW := 30    # ±30 days
const WINTER_MIN_STRIDE_DAYS := 3
const WINTER_MIN_HOUR := 5.0          # near the pre-dawn daily minimum


## Estimate a site's typical winter minimum temperature in °C from the weather
## service's hourly series, or NAN when no usable data exists (offline, or a
## location the archive doesn't cover). Species climate envelopes compare their
## cold-hardiness against this; NAN means "no opinion" and the caller falls
## back to the latitude gate alone, so an offline session never loses its
## forests. Duck-typed on `ws` exactly like estimate_snow_depth_m.
static func estimate_winter_min_c(ws: Object, latitude: float) -> float:
	if ws == null or not ws.has_method("temperature_c"):
		return NAN
	# The southern-hemisphere flip is the same half-year shift the phenology
	# calendar uses, so July reads as "winter" at a Patagonian site.
	var center := WINTER_MIN_CENTER_DOY
	if latitude < 0.0:
		center = fmod(center + YEAR_LEN * 0.5, YEAR_LEN)
	var coldest := INF
	var d := int(center) - WINTER_MIN_HALF_WINDOW
	while d <= int(center) + WINTER_MIN_HALF_WINDOW:
		var md := _doy_to_month_day(d)
		var t := float(ws.call("temperature_c", md.x, md.y, WINTER_MIN_HOUR))
		if is_finite(t):
			coldest = minf(coldest, t)
		d += WINTER_MIN_STRIDE_DAYS
	return coldest if is_finite(coldest) else NAN


## Ground snow cover tint strength 0..1 from pack depth.
static func estimate_snow_cover(ws: Object, month: int, day: int, hour: float, latitude: float) -> float:
	var depth := estimate_snow_depth_m(ws, month, day, hour, latitude)
	if depth <= 0.0:
		return 0.0
	return clampf(depth / COVER_DEPTH_M, 0.0, 1.0)


## Wrap a (possibly out-of-range) 1-based day-of-year to a Vector2i(month, day),
## using a non-leap calendar. Negative/over-365 values wrap around the year so a
## trailing window in January reads the previous December.
static func _doy_to_month_day(doy: int) -> Vector2i:
	var d := doy
	while d < 1:
		d += 365
	while d > 365:
		d -= 365
	for m in range(12):
		var dim: int = _DAYS_IN_MONTH[m]
		if d <= dim:
			return Vector2i(m + 1, d)
		d -= dim
	return Vector2i(12, 31)
