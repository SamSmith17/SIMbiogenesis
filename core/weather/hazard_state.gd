class_name HazardState
extends RefCounted

## The ONE contract between a hazard and everything that renders or simulates it.
##
## Every resolver in HazardEvaluators returns this shape, `combine()` merges
## concurrent hazards into it, and exactly four appliers consume it:
##   optics   -> AtmosphereApplier   (main.gd's WorldEnvironment)
##   dynamics -> DustSmokeVfx        (particles)
##   energy   -> SolarIrradiance / CSP / turbines, via weather["aod"] et al.
##   life     -> NpcWeatherGate / player_health
## Nothing else reads it. That is what keeps eleven hazards from becoming eleven
## subsystems.
##
## A plain Dictionary rather than a typed object, matching NpcWeatherGate,
## SolarIrradiance.sample_weather and CspTroughSource.simulate — it stays
## trivially constructible in an offline selftest with no scene tree.
##
## THREE INVARIANTS, each pinned by core/weather/extreme_weather_selftest.gd:
##  1. `blank()` is the IDENTITY. Every multiplier 1.0, every additive term 0.0.
##     `AtmosphereApplier.resolve(base, blank())` must return `base`
##     field-for-field — that single property IS the "feature off => zero visual
##     change" guarantee for the whole feature.
##  2. `combine(a, b)` is total and COMMUTATIVE, and `combine(a, blank()) == a`.
##     Smoke during a heatwave is the real Portland/Sacramento case; two hazards
##     must coexist without a special case anywhere.
##  3. Every numeric field is finite. `clampf` does NOT filter NaN (see the
##     GPU-hang comment in solar_ui.gd), and CAMS returns genuine null hours, so
##     NaN is a likely input here rather than a theoretical one.

## Visibility with no hazard at all. Well beyond main.gd's 8000 m fog_depth_end,
## so `blank()` cannot pull the horizon in.
const CLEAR_VISIBILITY_M := 100000.0

## Rayleigh-only extinction floor, ~10 Mm^-1 (Malm et al. 1994, IMPROVE) — the
## reason a perfectly clean atmosphere still tops out near 390 km of visibility
## rather than infinity.
const RAYLEIGH_BEXT_MM := 10.0


## The identity element. Also the authoritative key list — every other function
## here and every applier keys off exactly these names.
static func blank() -> Dictionary:
	return {
		# --- identity ---
		"id": "",
		"label": "",
		"severity": 0.0,
		"source": "none",          # alert | aq | weather | climatology | forced | none
		# --- optics ---
		"aod": 0.0,                # ADDED aerosol optical depth over the clean baseline
		"visibility_m": CLEAR_VISIBILITY_M,
		"haze_color": Color(0.68, 0.78, 0.94),   # main.gd's day_haze; neutral
		"haze_strength": 0.0,
		"sky_tint_strength": 0.0,
		"sun_tint": Color(1.0, 1.0, 1.0),
		"sun_energy_mult": 1.0,
		"glow_boost": 0.0,
		"exposure_offset": 0.0,
		# How much the sky tint favours the horizon over the zenith (sky.gdshader
		# hazard_horizon_bias). Smoke is a deep layer aloft and takes the whole
		# dome; blowing dust is a shallow layer on the ground and takes the
		# horizon while the zenith stays comparatively clear. 0.65 = the shader's
		# own default.
		"horizon_bias": 0.65,
		# Top of a GROUND-HUGGING aerosol layer, metres above the ground (0 = the
		# aerosol is well mixed / aloft, no layer). main.gd draws it as a
		# height-capped FogVolume, which is what makes dust read as low and thick.
		"haze_layer_m": 0.0,
		# How much of the sky the aerosol VEILS — drawn over the sun, moon,
		# clouds and stars at the very end of sky.gdshader (hazard_veil). The sky
		# tint above takes the gradient only, so the sun disc still shows through
		# smoke; a whiteout dust storm hides everything.
		"sky_veil": 0.0,
		# Visual-only thickness multiplier on the fog the applier derives from
		# visibility_m (the player's "Thickness" taste). visibility_m itself stays
		# physical, so nothing that reads it as data moves with a graphics slider.
		"optical_mult": 1.0,
		# Multiplier on ambient light after the applier's generic haze dimming. A
		# dust whiteout is a bright, shadowless diffuse light, not a dim one.
		"ambient_mult": 1.0,
		# --- dynamics ---
		"wind_mult": 1.0,
		"gust_mult": 1.0,
		"particle_kind": "",       # "" | "dust" (wildfire smoke deliberately emits none — see hazard_evaluators.gd)
		"particle_density": 0.0,
		"turbulence": 0.0,
		# --- energy ---
		"dni_factor": 1.0,
		"dhi_boost": 0.0,          # scattered light RISES as direct beam collapses
		"ghi_factor": 1.0,
		"wind_derate": 0.0,
		"grid_available": true,
		# --- life ---
		"breath_hazard": 0.0,
		"pm25_ugm3": 0.0,
		"aqi": 0.0,
		"thermal_stress": 0.0,     # -1 lethal cold .. +1 lethal heat
		"shelter_required": false,
	}


## Coerce anything missing/NaN back onto the identity. Every resolver returns
## through this, so a partial dict from a half-written hazard can never leak a
## NaN into a shader uniform.
static func sanitize(d: Dictionary) -> Dictionary:
	var out := blank()
	for key: String in out.keys():
		if not d.has(key):
			continue
		var v: Variant = d[key]
		var proto: Variant = out[key]
		if proto is float:
			var f := float(v)
			out[key] = f if is_finite(f) else float(proto)
		elif proto is bool:
			out[key] = bool(v)
		elif proto is Color:
			var c: Color = v if v is Color else (proto as Color)
			out[key] = c if _color_finite(c) else (proto as Color)
		else:
			out[key] = str(v)
	out["severity"] = clampf(float(out["severity"]), 0.0, 1.0)
	out["visibility_m"] = maxf(float(out["visibility_m"]), 1.0)
	out["aod"] = maxf(float(out["aod"]), 0.0)
	return out


static func _color_finite(c: Color) -> bool:
	return is_finite(c.r) and is_finite(c.g) and is_finite(c.b) and is_finite(c.a)


static func is_active(d: Dictionary) -> bool:
	return float(d.get("severity", 0.0)) > 0.005


## Merge two concurrent hazards. Commutative and total by construction:
##  * optics/life take the WORST (min visibility, max aod/haze/breath) — you do
##    not get to see further because a second hazard arrived;
##  * energy factors MULTIPLY — smoke and dust each attenuate independently, so
##    stacking them must compound rather than merely take the larger;
##  * colours blend weighted by severity, so the dominant hazard sets the tint;
##  * thermal_stress takes the larger ABSOLUTE value, keeping its sign — a
##    heatwave and a cold snap cannot cancel into "comfortable".
static func combine(a: Dictionary, b: Dictionary) -> Dictionary:
	if not is_active(a):
		return sanitize(b)
	if not is_active(b):
		return sanitize(a)
	var sa := float(a.get("severity", 0.0))
	var sb := float(b.get("severity", 0.0))
	var out := blank()

	# The louder hazard owns the identity, so toasts and the HUD name the thing
	# the player is actually looking at.
	var dom: Dictionary = a if sa >= sb else b
	out["id"] = str(dom.get("id", ""))
	out["label"] = str(dom.get("label", ""))
	out["source"] = str(dom.get("source", "none"))
	out["severity"] = maxf(sa, sb)

	out["aod"] = float(a.get("aod", 0.0)) + float(b.get("aod", 0.0))
	out["visibility_m"] = minf(
		float(a.get("visibility_m", CLEAR_VISIBILITY_M)),
		float(b.get("visibility_m", CLEAR_VISIBILITY_M)))
	out["haze_strength"] = maxf(float(a.get("haze_strength", 0.0)), float(b.get("haze_strength", 0.0)))
	out["sky_tint_strength"] = maxf(
		float(a.get("sky_tint_strength", 0.0)), float(b.get("sky_tint_strength", 0.0)))
	out["haze_color"] = _blend_color(a.get("haze_color"), b.get("haze_color"), sa, sb)
	out["sun_tint"] = _blend_color(a.get("sun_tint"), b.get("sun_tint"), sa, sb)
	out["horizon_bias"] = _blend_float(
		float(a.get("horizon_bias", 0.65)), float(b.get("horizon_bias", 0.65)), sa, sb)
	out["haze_layer_m"] = maxf(float(a.get("haze_layer_m", 0.0)), float(b.get("haze_layer_m", 0.0)))
	out["sky_veil"] = maxf(float(a.get("sky_veil", 0.0)), float(b.get("sky_veil", 0.0)))
	out["optical_mult"] = maxf(float(a.get("optical_mult", 1.0)), float(b.get("optical_mult", 1.0)))
	out["ambient_mult"] = maxf(float(a.get("ambient_mult", 1.0)), float(b.get("ambient_mult", 1.0)))
	out["sun_energy_mult"] = float(a.get("sun_energy_mult", 1.0)) * float(b.get("sun_energy_mult", 1.0))
	out["glow_boost"] = maxf(float(a.get("glow_boost", 0.0)), float(b.get("glow_boost", 0.0)))
	out["exposure_offset"] = minf(
		float(a.get("exposure_offset", 0.0)), float(b.get("exposure_offset", 0.0)))

	out["wind_mult"] = maxf(float(a.get("wind_mult", 1.0)), float(b.get("wind_mult", 1.0)))
	out["gust_mult"] = maxf(float(a.get("gust_mult", 1.0)), float(b.get("gust_mult", 1.0)))
	# The denser particle field wins outright rather than blending — there is
	# one emitter, and this stays a MAX (not additive) even with a single
	# particle kind today, since a future second kind must not be able to
	# average into something neither hazard actually looks like.
	var pa := float(a.get("particle_density", 0.0))
	var pb := float(b.get("particle_density", 0.0))
	var pdom: Dictionary = a if pa >= pb else b
	out["particle_kind"] = str(pdom.get("particle_kind", ""))
	out["particle_density"] = maxf(pa, pb)
	out["turbulence"] = maxf(float(a.get("turbulence", 0.0)), float(b.get("turbulence", 0.0)))

	out["dni_factor"] = float(a.get("dni_factor", 1.0)) * float(b.get("dni_factor", 1.0))
	out["ghi_factor"] = float(a.get("ghi_factor", 1.0)) * float(b.get("ghi_factor", 1.0))
	out["dhi_boost"] = maxf(float(a.get("dhi_boost", 0.0)), float(b.get("dhi_boost", 0.0)))
	out["wind_derate"] = maxf(float(a.get("wind_derate", 0.0)), float(b.get("wind_derate", 0.0)))
	out["grid_available"] = bool(a.get("grid_available", true)) and bool(b.get("grid_available", true))

	out["breath_hazard"] = maxf(float(a.get("breath_hazard", 0.0)), float(b.get("breath_hazard", 0.0)))
	out["pm25_ugm3"] = maxf(float(a.get("pm25_ugm3", 0.0)), float(b.get("pm25_ugm3", 0.0)))
	out["aqi"] = maxf(float(a.get("aqi", 0.0)), float(b.get("aqi", 0.0)))
	var ta := float(a.get("thermal_stress", 0.0))
	var tb := float(b.get("thermal_stress", 0.0))
	out["thermal_stress"] = ta if absf(ta) >= absf(tb) else tb
	out["shelter_required"] = bool(a.get("shelter_required", false)) \
			or bool(b.get("shelter_required", false))
	return sanitize(out)


static func combine_all(states: Array) -> Dictionary:
	var out := blank()
	for s: Variant in states:
		if s is Dictionary:
			out = combine(out, s as Dictionary)
	return out


static func _blend_float(a: float, b: float, sa: float, sb: float) -> float:
	var total := sa + sb
	if total <= 0.0001:
		return a
	return (a * sa + b * sb) / total


static func _blend_color(a: Variant, b: Variant, sa: float, sb: float) -> Color:
	var ca: Color = a if a is Color else Color(1, 1, 1)
	var cb: Color = b if b is Color else Color(1, 1, 1)
	var total := sa + sb
	if total <= 0.0001:
		return ca
	return ca.lerp(cb, clampf(sb / total, 0.0, 1.0))


## --- Optics helpers (cited; used by resolvers and the applier alike) ---------

## Koschmieder's law at the conventional 2% contrast threshold:
##   V = 3.912 / b_ext
## Godot's exponential fog is exp(-density * d), i.e. density IS b_ext, so this
## converts a visibility target straight into a fog density with no free
## parameter to hand-tune.
static func fog_density_for_visibility(visibility_m: float) -> float:
	if not is_finite(visibility_m) or visibility_m <= 1.0:
		return 3.912
	return 3.912 / visibility_m


static func visibility_for_fog_density(density: float) -> float:
	if not is_finite(density) or density <= 0.0000001:
		return CLEAR_VISIBILITY_M
	return 3.912 / density


## Mass extinction efficiency of DRY FINE aerosol, m^2/g — the IMPROVE
## reconstruction's standard coefficient (Malm et al. 1994, J. Geophys. Res.
## 99:1347). Correct for generic urban/background haze.
const MEE_FINE_DRY := 3.0

## Mass extinction efficiency of BIOMASS-BURNING (smoke) aerosol, m^2/g. Smoke
## particles sit near the peak of the Mie scattering curve for visible light and
## extinguish substantially more per unit mass than generic fine aerosol;
## reported values cluster around 3.5-4.7 (Reid et al. 2005, Atmos. Chem. Phys.
## 5:827, "A review of biomass burning particle properties"). Using the dry-fine
## 3.0 for smoke overestimates visibility by roughly half.
const MEE_SMOKE := 4.4

## Mass extinction efficiency of COARSE MINERAL DUST, m^2/g. Far LOWER per unit
## mass than fine aerosol — coarse grains are inefficient scatterers for their
## weight — but dust storms carry orders of magnitude more mass, which is why a
## haboob is opaque while a smoke event is merely thick. Reported PM10 dust
## efficiencies run ~0.5-1.0 (Tegen & Lacis 1996, J. Geophys. Res. 101:19237).
const MEE_DUST_COARSE := 0.7


## Visibility from fine-particle mass, via the IMPROVE reconstruction: extinction
## is the aerosol's mass extinction efficiency times its concentration, plus the
## Rayleigh floor. `rh_factor` is the hygroscopic growth term f(RH), ~1 in dry
## air and rising sharply above 70% RH. `mee` selects the aerosol type — pass
## MEE_SMOKE for wildfire smoke, the MEE_FINE_DRY default for everything else.
static func visibility_from_pm25(pm25_ugm3: float, rh_factor: float = 1.0,
		mee: float = MEE_FINE_DRY) -> float:
	var pm := maxf(pm25_ugm3, 0.0) if is_finite(pm25_ugm3) else 0.0
	var f := clampf(rh_factor, 1.0, 4.0) if is_finite(rh_factor) else 1.0
	var k := clampf(mee, 0.5, 12.0) if is_finite(mee) else MEE_FINE_DRY
	var b_ext := k * f * pm + RAYLEIGH_BEXT_MM   # Mm^-1
	if b_ext <= 0.0:
		return CLEAR_VISIBILITY_M
	# b_ext is per megametre; 3.912 / (b_ext * 1e-6) gives metres.
	return clampf(3.912 / (b_ext * 0.000001), 20.0, CLEAR_VISIBILITY_M)


## Hygroscopic growth factor f(RH). Piecewise from the IMPROVE curve — flat in
## dry air, climbing steeply as RH approaches saturation, which is why humid
## smoke reads far thicker than the same mass of dry dust.
static func rh_growth_factor(rh_pct: float) -> float:
	if not is_finite(rh_pct):
		return 1.0
	var rh := clampf(rh_pct, 0.0, 100.0)
	if rh < 70.0:
		return 1.0
	if rh < 90.0:
		return lerpf(1.0, 2.1, (rh - 70.0) / 20.0)
	return lerpf(2.1, 3.6, clampf((rh - 90.0) / 10.0, 0.0, 1.0))
