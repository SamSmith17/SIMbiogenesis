class_name NpcWeatherGate
extends RefCounted

## Weather-driven productivity and exposure for outdoor work.
##
## Sources for the thresholds (project convention: cite, never invent):
##  * Heat/cold work limits follow ISO 7243 (WBGT) guidance for moderate
##    metabolic-rate work: sustained output degrades above ~26 C and becomes
##    unsafe near ~38 C; cold-weather manual work degrades below ~8 C and
##    becomes unsafe below ~-5 C (NIOSH cold-stress work/warm-up schedules).
##  * Wind bands follow the Beaufort scale: 8 m/s (Beaufort 5, "fresh breeze")
##    is where handling sheet goods gets awkward; 15 m/s (Beaufort 7, "near
##    gale") is the conventional stop-work threshold for work at height.
##  * Rain bands follow the standard meteorological intensity classes:
##    "light" <2.5 mm/h, "heavy" >7.6 mm/h; outdoor manual work degrades from
##    the onset of steady rain and stops in heavy rain.
##
## Pure static math over a weather sample dictionary:
##   {temp_c: float, wind_ms: float, rain_mmh: float}
## Missing keys degrade gracefully to "comfortable" so an offline site (no
## WeatherService coverage) never blocks work.

## Exposure classes a chore can declare.
const EXPOSURE_INDOOR := "indoor"
const EXPOSURE_SHELTERED := "sheltered"
const EXPOSURE_OUTDOOR := "outdoor"
const EXPOSURES: Array = [EXPOSURE_INDOOR, EXPOSURE_SHELTERED, EXPOSURE_OUTDOOR]

const TEMP_COMFORT_MIN := 8.0
const TEMP_COMFORT_MAX := 26.0
const TEMP_STOP_COLD := -5.0
const TEMP_STOP_HOT := 38.0

const WIND_COMFORT_MS := 8.0
const WIND_STOP_MS := 15.0

const RAIN_COMFORT_MMH := 0.5
const RAIN_STOP_MMH := 5.0

## Air quality, as US EPA AQI. 151 is the bottom of the "Unhealthy" category, and
## the threshold at which Cal/OSHA §5141.1 requires respirators for outdoor work
## — so it is where productivity starts to fall, not where discomfort starts.
## 300 is "Hazardous", where outdoor work stops.
const AIR_COMFORT_AQI := 151.0
const AIR_STOP_AQI := 300.0

## Air is the ONE driver that follows people indoors. exposure_factor() below
## returns 0.0 for INDOOR, which is right for rain and wind and wrong for smoke;
## rather than weaken that (every existing threshold depends on it) air uses its
## own factors. Values are measured residential PM2.5 infiltration ratios, which
## cluster in 0.3-0.7 for closed buildings without filtration (Chen & Zhao 2011,
## Atmos. Environ. 45:275).
const AIR_INDOOR_RELIEF := 0.35
const AIR_SHELTERED_RELIEF := 0.70

## However bad it gets, work that is still legal proceeds at this fraction.
const WEATHER_FLOOR := 0.15

## Morale drain per sim-hour spent working fully exposed in stopped-out
## conditions (scaled by how far past comfortable, and by exposure class).
const EXPOSURE_MORALE_PER_H := 0.06

## Sheltered work feels (and performs) this fraction of the full outdoor hit.
const SHELTER_RELIEF := 0.45


static func temp_c(weather: Dictionary) -> float:
	var t := float(weather.get("temp_c", NAN))
	return t if is_finite(t) else 18.0


static func wind_ms(weather: Dictionary) -> float:
	var w := float(weather.get("wind_ms", NAN))
	return w if is_finite(w) else 0.0


static func rain_mmh(weather: Dictionary) -> float:
	var r := float(weather.get("rain_mmh", NAN))
	return r if is_finite(r) else 0.0


static func aqi(weather: Dictionary) -> float:
	var a := float(weather.get("aqi", NAN))
	return a if is_finite(a) else 0.0


static func exposure_factor(exposure: String) -> float:
	match exposure:
		EXPOSURE_INDOOR: return 0.0
		EXPOSURE_SHELTERED: return SHELTER_RELIEF
	return 1.0


## Exposure factor for AIR specifically. Deliberately a second function rather
## than a change to the one above: walls stop rain and wind completely, but only
## damp smoke. Keeping them separate means adding this driver could not shift a
## single existing threshold — which the population selftest asserts directly.
static func air_exposure_factor(exposure: String) -> float:
	match exposure:
		EXPOSURE_INDOOR: return AIR_INDOOR_RELIEF
		EXPOSURE_SHELTERED: return AIR_SHELTERED_RELIEF
	return 1.0


## 0..1 severity per driver: 0 comfortable, 1 at the stop-work threshold.
static func _severity(value: float, comfort: float, stop: float) -> float:
	if stop == comfort:
		return 0.0
	return clampf((value - comfort) / (stop - comfort), 0.0, 1.0)


static func temp_severity(weather: Dictionary) -> float:
	var t := temp_c(weather)
	if t > TEMP_COMFORT_MAX:
		return _severity(t, TEMP_COMFORT_MAX, TEMP_STOP_HOT)
	if t < TEMP_COMFORT_MIN:
		return _severity(t, TEMP_COMFORT_MIN, TEMP_STOP_COLD)
	return 0.0


static func wind_severity(weather: Dictionary) -> float:
	return _severity(wind_ms(weather), WIND_COMFORT_MS, WIND_STOP_MS)


static func rain_severity(weather: Dictionary) -> float:
	return _severity(rain_mmh(weather), RAIN_COMFORT_MMH, RAIN_STOP_MMH)


static func air_severity(weather: Dictionary) -> float:
	return _severity(aqi(weather), AIR_COMFORT_AQI, AIR_STOP_AQI)


## Worst single driver, 0..1 — what "how bad is it out there" means.
## Air is combined with its OWN exposure factor, so it still bites indoors while
## the weather drivers correctly do not.
static func severity(weather: Dictionary, exposure: String = EXPOSURE_OUTDOOR) -> float:
	var air := air_severity(weather) * air_exposure_factor(exposure)
	var e := exposure_factor(exposure)
	if e <= 0.0:
		return air
	return maxf(maxf(maxf(temp_severity(weather), wind_severity(weather)),
			rain_severity(weather)) * e, air)


## Productivity multiplier for work of this exposure class. Drivers MULTIPLY,
## so a hot windy rainy day is genuinely brutal rather than merely additive.
static func productivity(weather: Dictionary, exposure: String = EXPOSURE_OUTDOOR) -> float:
	var air_f := 1.0 - air_severity(weather) * air_exposure_factor(exposure)
	var e := exposure_factor(exposure)
	if e <= 0.0:
		# Indoor work is immune to weather but not to smoke.
		return clampf(air_f, WEATHER_FLOOR, 1.0)
	var f := (1.0 - temp_severity(weather) * e) \
			* (1.0 - wind_severity(weather) * e) \
			* (1.0 - rain_severity(weather) * e) \
			* air_f
	return clampf(f, WEATHER_FLOOR, 1.0)


## Conditions past a stop-work threshold: the chore is skipped entirely
## (its window lapses and the work backs up).
static func is_unsafe(weather: Dictionary, exposure: String = EXPOSURE_OUTDOOR) -> bool:
	# Hazardous air stops even INDOOR work, before the early return below: an
	# unfiltered building during a Hazardous-category smoke event is not a
	# refuge, and this is the one hazard walls do not solve.
	if aqi(weather) >= AIR_STOP_AQI:
		return true
	if exposure == EXPOSURE_INDOOR:
		return false
	var t := temp_c(weather)
	if t >= TEMP_STOP_HOT or t <= TEMP_STOP_COLD:
		return true
	if wind_ms(weather) >= WIND_STOP_MS:
		return true
	# Sheltered work still happens in heavy rain; fully exposed work does not.
	if exposure == EXPOSURE_OUTDOOR and rain_mmh(weather) >= RAIN_STOP_MMH:
		return true
	return false


## Morale drain per sim-hour for someone working in these conditions.
static func exposure_morale_drain(weather: Dictionary, exposure: String) -> float:
	return EXPOSURE_MORALE_PER_H * severity(weather, exposure)


## Player-facing one-liner for the routines UI.
static func describe(weather: Dictionary, exposure: String = EXPOSURE_OUTDOOR) -> String:
	if is_unsafe(weather, exposure):
		return "unsafe — outdoor work stopped"
	var p := productivity(weather, exposure)
	if p >= 0.98:
		return "good working weather"
	var worst := "conditions"
	var ts := temp_severity(weather)
	var ws := wind_severity(weather)
	var rs := rain_severity(weather)
	var as_ := air_severity(weather) * air_exposure_factor(exposure)
	if as_ >= ts and as_ >= ws and as_ >= rs:
		worst = "smoke"
	elif ts >= ws and ts >= rs:
		worst = "heat" if temp_c(weather) > TEMP_COMFORT_MAX else "cold"
	elif ws >= rs:
		worst = "wind"
	else:
		worst = "rain"
	return "%s slowing work (%d%%)" % [worst, int(round(p * 100.0))]
