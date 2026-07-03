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

const _DAYS_BEFORE_MONTH := [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
const _DAYS_IN_MONTH := [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

## Degree-day snow model tuning.
const SNOW_T_THRESHOLD_C := 1.0   # precip below this falls as snow
const MELT_T_BASE_C := 0.0        # melt accrues above this
const MELT_RATE_MM_PER_DEG_DAY := 2.6
const SNOW_WINDOW_DAYS := 70       # trailing days integrated
const SNOW_SAMPLE_STRIDE_DAYS := 2 # sample every N days for cost
const SWE_FULL_MM := 22.0          # snow-water-equiv for full white cover
const SNOW_DEPTH_FULL_M := 0.10    # modelled snow_depth for full white cover


## Map a 1-based day-of-year to its northern-hemisphere phenological equivalent,
## flipping by half a year in the southern hemisphere.
static func to_nh_doy(day_of_year: int, latitude: float) -> float:
	var doy := float(day_of_year)
	if latitude < 0.0:
		doy = fmod(doy + YEAR_LEN * 0.5, YEAR_LEN)
		if doy < 1.0:
			doy += YEAR_LEN
	return doy


## All phenology signals for a date. Values are 0..1 unless noted.
##  leaf_coverage : 1 = full canopy, 0 = bare (drives deciduous leaf-loss)
##  autumn        : warm-colour blend strength (yellow/orange/red)
##  bud           : spring fresh-growth tint strength
##  summer        : warm-season lushness
##  winter        : cold-season dormancy (grass browning, general desaturation)
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

	return {
		"leaf_coverage": leaf,
		"autumn": autumn,
		"bud": bud,
		"summer": summer,
		"winter": winter,
		"grass_growth": grass_growth,
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


## Estimate ground snow cover (0..1) at a date. `ws` is the WeatherService
## (or null). Prefers real modelled snow_depth; otherwise integrates a
## degree-day snowpack over the trailing window from temperature + precip.
static func estimate_snow_cover(ws: Object, month: int, day: int, hour: float, latitude: float) -> float:
	if ws != null and ws.has_method("has_snow_data") and bool(ws.call("has_snow_data", month, day, hour)):
		var depth := float(ws.call("snow_depth_m", month, day, hour))
		if is_finite(depth):
			return clampf(depth / SNOW_DEPTH_FULL_M, 0.0, 1.0)

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

	return clampf(swe / SWE_FULL_MM, 0.0, 1.0)


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
