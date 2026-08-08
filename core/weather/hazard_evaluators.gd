class_name HazardEvaluators
extends RefCounted

## How each hazard LOOKS and BEHAVES at a given severity.
##
## This is the file that keeps eleven hazards from becoming eleven subsystems:
## every hazard is one `_profile_*` function mapping severity 0..1 onto the
## shared HazardState contract, and everything downstream — atmosphere, VFX,
## irradiance, NPCs, health — reads that one shape.
##
## Severity ITSELF (data -> 0..1) is resolved by ExtremeWeather's ladder; this
## file answers the separate question "given that it is this bad, what is true?"
## Keeping the two apart is what lets an alert-driven event, a measured event
## and a forced preview all render identically.
##
## PHYSICS CONVENTION. Project rule is to cite sources and never invent
## constants. `aod` (aerosol optical depth) is the AUTHORITATIVE physical
## quantity here — SolarIrradiance consumes it directly through Beer-Lambert.
## `dni_factor` / `ghi_factor` are DERIVED SUMMARIES at a reference air mass,
## used for HUD readouts and for HazardState.combine's algebra; they must never
## be multiplied into the irradiance path on top of `aod`, or the attenuation
## is applied twice.

## Reference air mass for the derived display factors: air mass 1.5 is the
## standard AM1.5 spectrum condition (IEC 60904-3), i.e. sun ~42 degrees up.
const REFERENCE_AIR_MASS := 1.5

## Wind speed at which lifted dust starts to glow rather than merely darken.
## Saltation — the process that lifts dust at all — begins near 6-8 m/s at 10 m
## over loose dry soil (Bagnold 1941; Shao 2008, "Physics and Modelling of Wind
## Erosion"). Below this a dust hazard is haze; above it, it is a wall.
const DUST_EMISSIVE_WIND_MS := 15.0

## PM2.5 at severity 1.0, ug/m3. Severity 1.0 means the observed EXTREME TAIL,
## not merely the start of a bad band: the EPA "Hazardous" category begins at
## 225 ug/m3, but hourly monitors during the September 2020 Pacific Northwest
## fires read past 600, and Portland/Salem sat above 400 for days. Anchoring the
## top of the scale at the band boundary instead of the tail is what made an
## earlier draft of this curve render a hazardous day as light haze.
const SMOKE_PM25_MAX := 600.0

## Peak added aerosol optical depth at 550 nm. Dense wildfire smoke plumes are
## routinely measured at AOD 2-4 by AERONET; severe dust events run higher
## still, which is why dust darkens faster than smoke for the same severity.
const SMOKE_AOD_MAX := 2.6
const DUST_AOD_MAX := 3.4

## PM10 at severity 1.0, ug/m3. Dust storms carry mass in a range nothing else
## approaches: the 5 July 2011 Phoenix haboob drove PM10 monitors past
## 10,000 ug/m3, and Saharan and Gobi events are comparable. The superlinear
## exponent below is what makes mild dust read as haze and severe dust as a
## wall, instead of the near-linear ramp an earlier draft used — that one did
## nothing until 0.8 severity and then collapsed to 90 m in the last fifth.
const DUST_PM10_MAX := 15000.0
const DUST_PM10_EXPONENT := 2.2
## Fine fraction of airborne dust, for the AQI/health channel. Mineral dust is
## coarse-dominated; roughly 10-20% of PM10 mass falls in the PM2.5 range.
const DUST_FINE_FRACTION := 0.15


## Entry point used by the director. Unknown or unsimulated ids return blank(),
## so a catalog row without a profile degrades to "nothing happens" rather than
## to a crash.
static func state_for(id: String, severity: float, source: String = "weather") -> Dictionary:
	var sev := clampf(severity, 0.0, 1.0) if is_finite(severity) else 0.0
	if sev <= 0.005:
		return HazardState.blank()
	var s: Dictionary
	match id:
		"wildfire_smoke": s = _profile_wildfire_smoke(sev)
		"dust_storm": s = _profile_dust_storm(sev)
		"damaging_winds": s = _profile_damaging_winds(sev)
		"heatwave": s = _profile_heatwave(sev)
		_: return HazardState.blank()
	s["id"] = id
	s["label"] = HazardCatalog.display_name(id)
	s["severity"] = sev
	s["source"] = source
	return HazardState.sanitize(s)


## --- severity from measured data ---------------------------------------------
##
## Each `evaluate_*` maps one SAMPLE dict onto a 0..1 severity. The sample is
## assembled by ExtremeWeather from AirQualityService + WeatherService, with
## keys: pm25, pm10, dust, aod, us_aqi, wind_ms, gust_ms, temp_c, rain_mmh,
## humidity_pct, heat_threshold_c, has_aq.
##
## Missing keys read as NAN and yield 0 severity — an offline site raises no
## hazards rather than false ones.

## Saltation threshold: the 10 m wind speed at which loose dry soil begins to
## move and lift dust at all. Bagnold (1941) and Shao (2008) put it near
## 6-8 m/s for erodible surfaces; below it, airborne dust is transported from
## elsewhere rather than raised locally.
const DUST_SALTATION_WIND_MS := 7.0
## Wind at which local dust lofting is fully developed.
const DUST_FULL_WIND_MS := 22.0

## Dust concentration (ug/m3) mapping to full severity. Matches DUST_PM10_MAX so
## the measured path and the forced/preview path agree at the top of the scale.
const DUST_CONC_FULL := 15000.0

## Recent rainfall that suppresses dust entirely — wet ground does not lift.
const DUST_RAIN_SUPPRESS_MMH := 0.4

## Fine-mode fraction (PM2.5 / PM10) separating smoke from dust. Biomass smoke
## is overwhelmingly fine (typically 0.7-0.9); mineral dust is coarse-dominated
## (0.15-0.4). This ratio is how a smoke evaluator avoids firing on a dust storm
## and vice versa, using data both events push in the same direction.
const FINE_FRACTION_SMOKE := 0.6
const FINE_FRACTION_DUST := 0.4

## Beaufort-scale wind bands. 17 m/s is Beaufort 8 ("gale", twigs break, walking
## impeded); 25 m/s is Beaufort 10 ("storm", structural damage). NWS High Wind
## Warning criteria sit in between (sustained 18 m/s or gusts 26 m/s).
const WIND_DAMAGE_ONSET_MS := 17.0
const WIND_DAMAGE_FULL_MS := 25.0
const GUST_DAMAGE_ONSET_MS := 22.0
const GUST_DAMAGE_FULL_MS := 33.0

## Heat severity is measured against the SITE's own threshold, not an absolute:
## 38 C is a heatwave in Portland and an ordinary Tuesday in Phoenix. The
## director supplies `heat_threshold_c` from local climatology; this is the
## fallback when it has none.
const HEAT_THRESHOLD_DEFAULT_C := 35.0
const HEAT_FULL_OVERSHOOT_C := 12.0


static func evaluate(id: String, sample: Dictionary) -> float:
	match id:
		"wildfire_smoke": return evaluate_wildfire_smoke(sample)
		"dust_storm": return evaluate_dust_storm(sample)
		"damaging_winds": return evaluate_damaging_winds(sample)
		"heatwave": return evaluate_heatwave(sample)
	return 0.0


## Smoke severity from particulate load, gated on the aerosol actually being
## FINE-mode. Without that gate a haboob — which pushes PM2.5, PM10 and AOD up
## together — would raise a wildfire-smoke event too, and the player would see
## an orange sky with no fire anywhere.
static func evaluate_wildfire_smoke(sample: Dictionary) -> float:
	var pm25 := _num(sample, "pm25")
	if not is_finite(pm25) or pm25 <= 0.0:
		return 0.0
	var sev := clampf(pm25 / SMOKE_PM25_MAX, 0.0, 1.0)
	# Undo the display curve so severity round-trips through _profile_wildfire_smoke.
	sev = pow(sev, 1.0 / 1.4)

	var fine := _fine_fraction(sample)
	if is_finite(fine):
		# Coarse-dominated aerosol is dust, not smoke: fade this hazard out
		# rather than switching it off abruptly, so a mixed event reads as both.
		sev *= clampf((fine - FINE_FRACTION_DUST)
			/ maxf(FINE_FRACTION_SMOKE - FINE_FRACTION_DUST, 0.001), 0.0, 1.0)

	# Optical depth corroborates: a PM2.5 spike with no AOD rise is a
	# ground-level inversion, not a plume overhead.
	var aod := _num(sample, "aod")
	if is_finite(aod) and aod >= 0.0:
		sev *= clampf(0.55 + aod / SMOKE_AOD_MAX, 0.0, 1.0)
	return clampf(sev, 0.0, 1.0)


## Dust severity needs BOTH airborne dust and wind to raise it — and dies on wet
## ground. Concentration alone would fire on transported Saharan dust aloft on a
## still day, which is a hazy sky, not a dust storm.
static func evaluate_dust_storm(sample: Dictionary) -> float:
	var dust := _num(sample, "dust")
	# `dust` is a global-model-only field; fall back to the coarse fraction of
	# PM10 where CAMS Europe does not supply it.
	if not is_finite(dust):
		var pm10 := _num(sample, "pm10")
		var pm25 := _num(sample, "pm25")
		if is_finite(pm10) and is_finite(pm25):
			dust = maxf(pm10 - pm25, 0.0)
	if not is_finite(dust) or dust <= 0.0:
		return 0.0

	var conc := clampf(dust / DUST_CONC_FULL, 0.0, 1.0)
	conc = pow(conc, 1.0 / DUST_PM10_EXPONENT)

	var wind := _num(sample, "wind_ms")
	var wind_gate := 1.0
	if is_finite(wind):
		wind_gate = clampf(
			(wind - DUST_SALTATION_WIND_MS)
				/ maxf(DUST_FULL_WIND_MS - DUST_SALTATION_WIND_MS, 0.001),
			0.0, 1.0)
		# Transported dust aloft still hazes the sky without local lofting, so
		# the gate floors rather than zeroes.
		wind_gate = lerpf(0.25, 1.0, wind_gate)

	var rain := _num(sample, "rain_mmh")
	var wet_gate := 1.0
	if is_finite(rain) and rain > 0.0:
		wet_gate = clampf(1.0 - rain / DUST_RAIN_SUPPRESS_MMH, 0.0, 1.0)

	# Coarse-mode check, the mirror of the smoke gate.
	var fine := _fine_fraction(sample)
	var coarse_gate := 1.0
	if is_finite(fine):
		coarse_gate = clampf((FINE_FRACTION_SMOKE - fine)
			/ maxf(FINE_FRACTION_SMOKE - FINE_FRACTION_DUST, 0.001), 0.0, 1.0)

	return clampf(conc * wind_gate * wet_gate * coarse_gate, 0.0, 1.0)


## Wind damage from the WORSE of sustained speed and gusts. Gusts are what
## actually break things, and they are the channel nothing in this project read
## until now.
static func evaluate_damaging_winds(sample: Dictionary) -> float:
	var wind := _num(sample, "wind_ms")
	var gust := _num(sample, "gust_ms")
	var s_wind := 0.0
	var s_gust := 0.0
	if is_finite(wind):
		s_wind = clampf((wind - WIND_DAMAGE_ONSET_MS)
			/ maxf(WIND_DAMAGE_FULL_MS - WIND_DAMAGE_ONSET_MS, 0.001), 0.0, 1.0)
	if is_finite(gust):
		s_gust = clampf((gust - GUST_DAMAGE_ONSET_MS)
			/ maxf(GUST_DAMAGE_FULL_MS - GUST_DAMAGE_ONSET_MS, 0.001), 0.0, 1.0)
	return maxf(s_wind, s_gust)


## Heat severity relative to the SITE's own climatology, so the same absolute
## temperature is an emergency in one place and unremarkable in another.
## Humidity raises it: the body sheds heat by evaporation, so humid heat is
## physiologically worse at equal temperature (the basis of the heat index,
## NWS/Rothfusz 1990).
static func evaluate_heatwave(sample: Dictionary) -> float:
	var t := _num(sample, "temp_c")
	if not is_finite(t):
		return 0.0
	var threshold := _num(sample, "heat_threshold_c")
	if not is_finite(threshold):
		threshold = HEAT_THRESHOLD_DEFAULT_C
	var sev := clampf((t - threshold) / HEAT_FULL_OVERSHOOT_C, 0.0, 1.0)
	if sev <= 0.0:
		return 0.0
	var rh := _num(sample, "humidity_pct")
	if is_finite(rh) and rh > 40.0:
		sev *= lerpf(1.0, 1.35, clampf((rh - 40.0) / 50.0, 0.0, 1.0))
	return clampf(sev, 0.0, 1.0)


## PM2.5 / PM10 — the fine-mode fraction that tells smoke from dust. NAN when
## either is missing or PM10 is zero.
static func _fine_fraction(sample: Dictionary) -> float:
	var pm25 := _num(sample, "pm25")
	var pm10 := _num(sample, "pm10")
	if not is_finite(pm25) or not is_finite(pm10) or pm10 <= 0.1:
		return NAN
	return clampf(pm25 / pm10, 0.0, 1.0)


static func _num(sample: Dictionary, key: String) -> float:
	var v := float(sample.get(key, NAN))
	return v if is_finite(v) else NAN


## --- profiles ----------------------------------------------------------------

## Wildfire smoke. The signature look: the sun becomes a dim red disc, the sky
## loses its blue entirely, and the far distance simply stops existing — while
## the scene stays deceptively BRIGHT, because smoke scatters rather than
## absorbs. That last part is why a smoky day feels survivable and PV output
## still collapses.
static func _profile_wildfire_smoke(sev: float) -> Dictionary:
	var s := HazardState.blank()
	var pm25 := SMOKE_PM25_MAX * pow(sev, 1.4)   # slow start, brutal top end
	var aod := SMOKE_AOD_MAX * sev

	s["pm25_ugm3"] = pm25
	s["aqi"] = us_aqi_from_pm25(pm25)
	s["aod"] = aod
	# Smoke-specific extinction efficiency, not the generic dry-fine default —
	# see HazardState.MEE_SMOKE.
	s["visibility_m"] = HazardState.visibility_from_pm25(
		pm25, 1.0, HazardState.MEE_SMOKE)

	s["haze_color"] = Color(0.42, 0.20, 0.09).lerp(Color(0.72, 0.34, 0.13), 1.0 - sev)
	s["haze_strength"] = clampf(sev * 1.05, 0.0, 1.0)
	s["sky_tint_strength"] = clampf(sev * 0.95, 0.0, 1.0)
	# The disc reddens hard and dims: short wavelengths scatter out of the beam
	# first, which is the whole reason a smoke sun is orange.
	s["sun_tint"] = Color(1.0, 1.0, 1.0).lerp(Color(1.0, 0.34, 0.12), sev)
	s["sun_energy_mult"] = lerpf(1.0, 0.30, sev)
	# A diffused sun is a large soft source, so it blooms MORE even while
	# delivering less energy.
	s["glow_boost"] = sev * 0.9
	s["exposure_offset"] = -0.16 * sev

	s["dni_factor"] = beer_lambert(aod)
	s["ghi_factor"] = lerpf(1.0, 0.55, sev)
	# Forward-scattered light: direct beam collapses into diffuse rather than
	# vanishing, so DHI climbs as DNI falls.
	s["dhi_boost"] = 0.55 * sev

	# No particle system: a drifting-ash emitter reads as sparks at night (or
	# wherever the emissive bloom picks up the grains), which is the wrong
	# image for smoke that is mostly just thick, hazy air — the fog/haze the
	# atmosphere applier already produces carries the whole effect. Leaving
	# particle_kind/particle_density at HazardState.blank()'s "" / 0.0 default
	# is itself the decision, not an oversight.
	# Derived from SEVERITY, not from the AQI. The US index is defined to
	# truncate at 500, which smoke reaches by about 0.6 severity — deriving the
	# gameplay channel from it would make every event from 0.6 upward feel
	# identical to the player and to the NPC work gate. The displayed `aqi`
	# stays truncated because that is what the real index does; this does not.
	s["breath_hazard"] = clampf((sev - 0.15) / 0.85, 0.0, 1.0)
	s["shelter_required"] = sev >= 0.55
	return s


## Dust storm. Optically thicker and far more abrupt than smoke, and — above
## the saltation wind threshold — genuinely self-luminous: sunlight scattered
## inside the dust volume is what makes a haboob glow from within rather than
## reading as brown fog.
static func _profile_dust_storm(sev: float) -> Dictionary:
	var s := HazardState.blank()
	var aod := DUST_AOD_MAX * sev
	# Visibility comes from the same extinction law as smoke, differing only in
	# the aerosol's mass and efficiency — so the two hazards are comparable by
	# construction rather than by two independently tuned curves.
	var pm10 := DUST_PM10_MAX * pow(sev, DUST_PM10_EXPONENT)
	var pm25 := pm10 * DUST_FINE_FRACTION

	s["aod"] = aod
	s["visibility_m"] = HazardState.visibility_from_pm25(
		pm10, 1.0, HazardState.MEE_DUST_COARSE)
	s["pm25_ugm3"] = pm25
	s["aqi"] = us_aqi_from_pm25(pm25)

	s["haze_color"] = Color(0.78, 0.58, 0.33).lerp(Color(0.66, 0.42, 0.19), sev)
	s["haze_strength"] = clampf(sev * 1.15, 0.0, 1.0)
	s["sky_tint_strength"] = clampf(sev * 1.1, 0.0, 1.0)
	s["sun_tint"] = Color(1.0, 1.0, 1.0).lerp(Color(1.0, 0.62, 0.24), sev)
	s["sun_energy_mult"] = lerpf(1.0, 0.16, sev)
	s["glow_boost"] = sev * 1.2
	s["exposure_offset"] = -0.20 * sev

	s["dni_factor"] = beer_lambert(aod)
	s["ghi_factor"] = lerpf(1.0, 0.42, sev)
	s["dhi_boost"] = 0.35 * sev

	s["wind_mult"] = lerpf(1.0, 2.0, sev)
	s["gust_mult"] = lerpf(1.0, 2.2, sev)
	s["turbulence"] = sev
	s["particle_kind"] = "dust"
	s["particle_density"] = clampf(sev * 1.2, 0.0, 1.0)
	s["breath_hazard"] = clampf(sev * 1.1, 0.0, 1.0)
	s["shelter_required"] = sev >= 0.6
	return s


## Damaging winds. Deliberately almost invisible in the atmosphere — wind is not
## a haze — so it reads through motion, turbine shutdown and work stoppage
## instead. The one optical touch is a slight loss of clarity from lofted debris.
static func _profile_damaging_winds(sev: float) -> Dictionary:
	var s := HazardState.blank()
	s["wind_mult"] = lerpf(1.0, 2.6, sev)
	s["gust_mult"] = lerpf(1.0, 3.0, sev)
	s["turbulence"] = sev
	s["visibility_m"] = lerpf(HazardState.CLEAR_VISIBILITY_M, 9000.0, sev)
	s["haze_strength"] = 0.12 * sev
	s["haze_color"] = Color(0.60, 0.62, 0.66)
	# Turbines feather and shut down rather than degrade gracefully; the derate
	# is near-total once the hazard is severe.
	s["wind_derate"] = clampf((sev - 0.4) / 0.6, 0.0, 1.0)
	s["shelter_required"] = sev >= 0.7
	return s


## Heatwave. No optical signature worth faking (heat shimmer is a near-field
## effect the renderer has no path for), so this hazard lives entirely in the
## thermal and energy channels — PV derating and human limits.
static func _profile_heatwave(sev: float) -> Dictionary:
	var s := HazardState.blank()
	s["thermal_stress"] = sev
	# Cloudless heatwave skies are slightly whitened by haze trapped under the
	# inversion that causes them.
	s["haze_strength"] = 0.18 * sev
	s["haze_color"] = Color(0.80, 0.78, 0.70)
	s["visibility_m"] = lerpf(HazardState.CLEAR_VISIBILITY_M, 18000.0, sev)
	s["exposure_offset"] = 0.05 * sev
	s["shelter_required"] = sev >= 0.75
	return s


## --- shared physics ----------------------------------------------------------

## Beer-Lambert transmittance of the direct beam through an added aerosol layer:
##   T = exp(-tau * m)
## with tau the added optical depth and m the air mass. This is the same law
## SolarIrradiance's tau_a term already implements; using it here keeps the
## display factor consistent with the physics rather than a second guess at it.
static func beer_lambert(aod: float, air_mass: float = REFERENCE_AIR_MASS) -> float:
	if not is_finite(aod) or aod <= 0.0:
		return 1.0
	var m := clampf(air_mass, 1.0, 38.0) if is_finite(air_mass) else REFERENCE_AIR_MASS
	return clampf(exp(-aod * m), 0.0, 1.0)


## US EPA AQI for PM2.5, from the official piecewise-linear breakpoints
## (40 CFR Part 58 Appendix G; EPA 454/B-18-007 Table 4). Returned as a float so
## it interpolates smoothly for display rather than stepping between bands.
const AQI_BREAKPOINTS: Array = [
	# [conc_lo, conc_hi, aqi_lo, aqi_hi]
	[0.0, 9.0, 0.0, 50.0],
	[9.1, 35.4, 51.0, 100.0],
	[35.5, 55.4, 101.0, 150.0],
	[55.5, 125.4, 151.0, 200.0],
	[125.5, 225.4, 201.0, 300.0],
	[225.5, 325.4, 301.0, 500.0],
]


static func us_aqi_from_pm25(pm25: float) -> float:
	if not is_finite(pm25) or pm25 <= 0.0:
		return 0.0
	for bp: Array in AQI_BREAKPOINTS:
		var c_lo := float(bp[0])
		var c_hi := float(bp[1])
		if pm25 <= c_hi:
			var a_lo := float(bp[2])
			var a_hi := float(bp[3])
			if c_hi <= c_lo:
				return a_lo
			return a_lo + (a_hi - a_lo) * (pm25 - c_lo) / (c_hi - c_lo)
	return 500.0


## The EPA category name for an AQI value — used verbatim in the HUD and the
## NPC weather description, so players see the same words as a real air-quality
## report.
static func aqi_category(aqi: float) -> String:
	if not is_finite(aqi) or aqi <= 50.0:
		return "Good"
	if aqi <= 100.0:
		return "Moderate"
	if aqi <= 150.0:
		return "Unhealthy for Sensitive Groups"
	if aqi <= 200.0:
		return "Unhealthy"
	if aqi <= 300.0:
		return "Very Unhealthy"
	return "Hazardous"
