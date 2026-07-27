class_name HomeBiogasSource
extends RefCounted
## HomeBiogas 2.0 household biodigester physics.
##
## Datasheet (HomeBiogas 2.0):
##   Digester tank 1,200 L; gas storage bag 700 L; footprint 210×115×130 cm;
##   nominal gas pressure 10–15 mbar.
##   Daily feed: up to 6 L food waste OR 15 L animal manure, plus 6 L water.
##   Biogas at max food feed: ≈0.3–0.4 m³/day; at max manure: ≈0.56–0.7 m³/day
##   (≈60–65% CH₄). Cooking-gas equivalent ≈2–3 h/day on a single burner at
##   rated food feed.
##   Best biological performance above ~17–20 °C; colder climates need external
##   heating to stay active. Liquid organic fertilizer is produced continuously
##   as waste is added (digestate volume ≈ influent for a wet digester).
##
## Yield scales linearly with the player's daily feed setpoint (as a fraction of
## the mode's max) and with a temperature derate. Graph tick writes the resulting
## hourly I/O rates onto the processor specs; ResourceFlowEngine moves mass with
## `io_absolute` so multi-port liters/m³ rates stay numerically correct.

## Wet biogas density ballpark (≈60% CH₄ / 40% CO₂ at ambient), kg/m³.
const BIOGAS_DENSITY_KG_M3 := 1.15
const CH4_FRACTION_DEFAULT := 0.625

## Datasheet temperature band: full performance at/above TEMP_FULL_C; linear
## derate down to TEMP_FLOOR_C (near-zero methanogenesis without heating).
const TEMP_FULL_C := 20.0
const TEMP_FLOOR_C := 10.0
## Soft residual below the floor so a cold digester still shows a tiny trickle
## rather than a hard zero (matches "biologically inactive" without a cliff).
const TEMP_RESIDUAL := 0.05

const MAX_FOOD_L_DAY := 6.0
const MAX_MANURE_L_DAY := 15.0
const WATER_L_DAY_AT_MAX := 6.0

const BIOGAS_FOOD_MIN_M3_DAY := 0.30
const BIOGAS_FOOD_MAX_M3_DAY := 0.40
const BIOGAS_MANURE_MIN_M3_DAY := 0.56
const BIOGAS_MANURE_MAX_M3_DAY := 0.70

## Cooking-gas hours on a single burner at rated (max food) feed.
const COOKING_HOURS_MIN := 2.0
const COOKING_HOURS_MAX := 3.0


static func is_manure_mode(specs: Dictionary) -> bool:
	return str(specs.get("feed_mode", "food")).to_lower() == "manure"


static func feed_kind_for_mode(feed_mode: String) -> String:
	return "manure" if str(feed_mode).to_lower() == "manure" else "food_waste"


static func max_feed_l_day(specs: Dictionary) -> float:
	if is_manure_mode(specs):
		return maxf(float(specs.get("max_manure_l_day", MAX_MANURE_L_DAY)), 0.01)
	return maxf(float(specs.get("max_food_l_day", MAX_FOOD_L_DAY)), 0.01)


static func biogas_band_m3_day(specs: Dictionary) -> Vector2:
	if is_manure_mode(specs):
		return Vector2(
			float(specs.get("biogas_m3_day_manure_min", BIOGAS_MANURE_MIN_M3_DAY)),
			float(specs.get("biogas_m3_day_manure_max", BIOGAS_MANURE_MAX_M3_DAY)))
	return Vector2(
		float(specs.get("biogas_m3_day_food_min", BIOGAS_FOOD_MIN_M3_DAY)),
		float(specs.get("biogas_m3_day_food_max", BIOGAS_FOOD_MAX_M3_DAY)))


## Temperature derate: 1.0 at/above full_c, linear to TEMP_RESIDUAL at/below floor_c.
static func temp_factor(ambient_c: float, full_c: float = TEMP_FULL_C,
		floor_c: float = TEMP_FLOOR_C) -> float:
	if ambient_c >= full_c:
		return 1.0
	if ambient_c <= floor_c:
		return TEMP_RESIDUAL
	var span := maxf(full_c - floor_c, 0.001)
	return lerpf(TEMP_RESIDUAL, 1.0, (ambient_c - floor_c) / span)


## Instantaneous performance for one digester given specs + ambient temperature.
## `daily_feed_l` (on specs) is the operator setpoint; clamped to the mode max.
## Returns telemetry plus hourly port rates the graph tick stamps onto inputs/
## outputs for ResourceFlowEngine (`io_absolute` processors).
static func simulate(specs: Dictionary, ambient_c: float) -> Dictionary:
	var max_feed := max_feed_l_day(specs)
	var daily_feed := clampf(float(specs.get("daily_feed_l", max_feed)), 0.0, max_feed)
	var feed_frac := daily_feed / max_feed

	var full_c := float(specs.get("temp_full_c", TEMP_FULL_C))
	var floor_c := float(specs.get("temp_floor_c", TEMP_FLOOR_C))
	var tf := temp_factor(ambient_c, full_c, floor_c)

	var band := biogas_band_m3_day(specs)
	var biogas_rated := lerpf(band.x, band.y, 0.5)
	var biogas_m3_day := feed_frac * biogas_rated * tf

	# Dilution water tracks the datasheet's 6 L/day at max feed, scaled with
	# the feed setpoint so a half-loaded digester isn't force-fed full water.
	var water_l_day := feed_frac * float(specs.get("water_l_day_at_max", WATER_L_DAY_AT_MAX))

	# Wet AD: digestate volume ≈ influent (feed + water). Biogas mass leaving
	# the liquid is small (~1 kg/m³) — subtract it for mass bookkeeping.
	var biogas_kg_day := biogas_m3_day * BIOGAS_DENSITY_KG_M3
	var fertilizer_l_day := maxf(daily_feed + water_l_day - biogas_kg_day, 0.0)

	var ch4 := clampf(float(specs.get("ch4_fraction", CH4_FRACTION_DEFAULT)), 0.0, 1.0)
	var cooking_h := feed_frac * tf * lerpf(COOKING_HOURS_MIN, COOKING_HOURS_MAX, 0.5)

	return {
		"ambient_temp_c": ambient_c,
		"temp_factor": tf,
		"feed_fraction": feed_frac,
		"daily_feed_l": daily_feed,
		"water_l_day": water_l_day,
		"biogas_m3_day": biogas_m3_day,
		"fertilizer_l_day": fertilizer_l_day,
		"ch4_fraction": ch4,
		"methane_m3_day": biogas_m3_day * ch4,
		"cooking_hours_day": cooking_h,
		"feed_lph": daily_feed / 24.0,
		"water_lph": water_l_day / 24.0,
		"biogas_m3_h": biogas_m3_day / 24.0,
		"fertilizer_lph": fertilizer_l_day / 24.0,
		"feed_kind": feed_kind_for_mode(str(specs.get("feed_mode", "food"))),
	}
