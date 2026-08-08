class_name AtmosphereApplier
extends RefCounted

## Turns a HazardState into the WorldEnvironment values main.gd should write.
##
## PURE STATIC, taking and returning plain dictionaries and holding no Environment
## reference — which is what makes the look pinnable by an offline selftest. The
## application itself stays in main.gd, where the nodes are (the RenderProfile
## split, same reasoning).
##
## THE IDENTITY GUARANTEE. `resolve(base, HazardState.blank())` returns `base`
## field-for-field. That single property is what makes "extreme weather disabled
## => not one pixel changes" true across every existing scene and screenshot,
## and it is asserted in extreme_weather_selftest rather than assumed.
##
## FOG DENSITY IS DERIVED, NOT TUNED. Godot's exponential fog is exp(-density*d),
## so density IS the extinction coefficient, and Koschmieder's law
## (V = 3.912 / b_ext at the conventional 2% contrast threshold) converts a
## visibility target straight into it. See HazardState.fog_density_for_visibility.
##
## THE TRAP THIS FILE EXISTS TO AVOID. main.gd sets `fog_sky_affect = 0`, which
## means `fog_aerial_perspective` blends the RENDERED SKY COLOUR into distant
## geometry. Raising aerial perspective under smoke therefore pushes terrain
## toward BLUE — the exact opposite of the intended look. So haze LOWERS aerial
## perspective and gets its colour from fog density plus fog_light_color, while
## the sky is tinted separately through fog_sky_affect. An earlier draft of this
## design had it backwards and would have shipped blue smoke.

## Hazard fog may reach 200 m visibility. Real haboobs go below 100 m, but
## rendering the player effectively blind is worse play than it is realism.
const FOG_DENSITY_MAX := 0.020
## main.gd's own clean-air floor, preserved so a hazard can never CLEAR the air.
const FOG_DENSITY_MIN := 0.00008

## Distance at which fog reaches full opacity, as a multiple of visibility.
## Beyond ~4x the Koschmieder distance there is nothing left to see anyway, and
## pulling depth_end in is what produces the "the world ends 800 m away" read.
const DEPTH_END_VISIBILITY_MULT := 4.0
const DEPTH_END_MIN := 400.0
const DEPTH_END_MAX := 8000.0

## How far the sky itself is taken over at full haze. Daylight-gated: at night
## this must fall to zero or the sky goes brown and the stars vanish.
const SKY_AFFECT_MAX := 0.55

## Aerial perspective floor under heavy haze. See the trap note above — this
## moves DOWN, not up.
const AERIAL_HAZE_FLOOR := 0.15

## Smoke and dust are strongly forward-scattering (Mie asymmetry g ~ 0.6-0.8),
## so the region around the sun glows far more than clean air allows.
const SUN_SCATTER_HAZE := 0.26

## Volumetric fog: the dust wall lights from within rather than reading as brown
## fog. Gated on wind, because that is the difference between suspended haze and
## a driven front.
const VOL_DENSITY_MAX := 0.035
const VOL_LENGTH_M := 180.0
const VOL_SUN_ENERGY_MAX := 8.0


## `base` is the clean-air environment main.gd has already computed for this
## frame (night/twilight/eclipse all folded in). Returns the same keys, modified.
## Extra keys in `base` pass through untouched.
##
## `night_amount` 0..1 and `sun_height` (the sun's normalised height, <=0 below
## the horizon) come from main.gd's own environment update.
static func resolve(base: Dictionary, hz: Dictionary,
		night_amount: float = 0.0, sun_height: float = 1.0) -> Dictionary:
	var out := base.duplicate(true)
	var sev := float(hz.get("severity", 0.0))
	# Identity: an inactive hazard returns `base` untouched, field for field.
	if not is_finite(sev) or sev <= 0.005:
		return out

	var night := _clamp01(night_amount)
	var day := 1.0 - night
	var haze := _clamp01(float(hz.get("haze_strength", 0.0)))
	var vis := float(hz.get("visibility_m", HazardState.CLEAR_VISIBILITY_M))
	if not is_finite(vis) or vis <= 0.0:
		vis = HazardState.CLEAR_VISIBILITY_M

	# --- fog density: never below the clean-air baseline, so a mild hazard
	# cannot accidentally make the air CLEARER than it was.
	var base_density := _f(base, "fog_density", 0.0003)
	var hazard_density := HazardState.fog_density_for_visibility(vis)
	out["fog_density"] = clampf(maxf(base_density, hazard_density),
		FOG_DENSITY_MIN, FOG_DENSITY_MAX)

	# --- visibility: the strongest "I cannot see" cue.
	out["fog_depth_end"] = clampf(
		minf(_f(base, "fog_depth_end", DEPTH_END_MAX), vis * DEPTH_END_VISIBILITY_MULT),
		DEPTH_END_MIN, DEPTH_END_MAX)

	# --- colour.
	var haze_col: Color = hz.get("haze_color", Color(0.68, 0.78, 0.94))
	var base_col: Color = base.get("fog_light_color", haze_col)
	out["fog_light_color"] = base_col.lerp(haze_col, haze)

	# --- aerial perspective moves DOWN. See the header.
	out["fog_aerial_perspective"] = lerpf(
		_f(base, "fog_aerial_perspective", 0.5), AERIAL_HAZE_FLOOR, haze)

	# --- forward scattering around the sun.
	out["fog_sun_scatter"] = lerpf(
		_f(base, "fog_sun_scatter", 0.05), SUN_SCATTER_HAZE, haze * day)

	# --- the sky itself. Daylight-gated so night stays dark and starry.
	out["fog_sky_affect"] = _clamp01(
		SKY_AFFECT_MAX * _clamp01(float(hz.get("sky_tint_strength", 0.0))) * day)

	# --- light. Ambient dims AND flattens; the sun disc reddens and dims.
	out["ambient_energy"] = _f(base, "ambient_energy", 0.3) * lerpf(1.0, 0.62, haze * day)
	out["sun_tint"] = hz.get("sun_tint", Color.WHITE)
	var sun_mult := float(hz.get("sun_energy_mult", 1.0))
	out["sun_energy_mult"] = clampf(sun_mult, 0.0, 1.0) if is_finite(sun_mult) else 1.0

	# --- bloom. A diffused sun is a large soft source: it blooms MORE even
	# while delivering less energy, which is why the threshold drops as the
	# intensity rises.
	var glow_raw := float(hz.get("glow_boost", 0.0))
	var glow_boost := clampf(glow_raw, 0.0, 2.0) if is_finite(glow_raw) else 0.0
	out["glow_intensity"] = _f(base, "glow_intensity", 0.5) * (1.0 + glow_boost * 0.55 * day)
	out["glow_hdr_threshold"] = maxf(
		_f(base, "glow_hdr_threshold", 1.5) * (1.0 - 0.45 * glow_boost * day), 0.25)

	out["exposure_offset"] = _f(base, "exposure_offset", 0.0) \
		+ float(hz.get("exposure_offset", 0.0)) * day

	# --- volumetric: the emissive dust wall.
	var vol := volumetric_for(hz, sun_height)
	for k: String in vol.keys():
		out[k] = vol[k]
	return out


## Volumetric-fog settings for a hazard, separated because main.gd applies them
## through _apply_advanced_rendering_toggles (which OWNS volumetric fog) rather
## than at the environment choke point. Writing them in both places would have
## the settings panel's god-rays toggle silently erase the dust wall.
##
## `force` is what tells that function to override the player's volumetric-fog
## preference: a dust wall that only appears for players who happened to enable
## volumetric fog is not a feature.
static func volumetric_for(hz: Dictionary, sun_height: float = 1.0) -> Dictionary:
	var out := {
		"vol_force": false,
		"vol_density": 0.0,
		"vol_albedo": Color(1.0, 0.95, 0.85),
		"vol_emission": Color(0, 0, 0),
		"vol_emission_energy": 0.0,
		"vol_length": VOL_LENGTH_M,
		"vol_sun_energy": 0.0,
	}
	var kind := str(hz.get("particle_kind", ""))
	var sev := float(hz.get("severity", 0.0))
	if kind != "dust" or not is_finite(sev) or sev < 0.35:
		return out

	# Wind is what separates a glowing driven wall from suspended brown haze.
	var wind_mult := float(hz.get("wind_mult", 1.0))
	var drive := clampf((wind_mult - 1.3) / 0.7, 0.0, 1.0)
	if drive <= 0.01:
		return out

	# The glow is SUNLIGHT scattered inside the dust volume, so it fades with
	# the sun — a self-luminous wall at midnight would read as a bug.
	var lit := clampf(sun_height * 4.0, 0.0, 1.0) if is_finite(sun_height) else 1.0
	var amount := sev * drive
	out["vol_force"] = true
	out["vol_density"] = VOL_DENSITY_MAX * amount
	out["vol_albedo"] = Color(0.85, 0.66, 0.42)
	out["vol_emission"] = Color(0.85, 0.60, 0.32)
	out["vol_emission_energy"] = amount * lit * 1.6
	out["vol_sun_energy"] = 1.0 + VOL_SUN_ENERGY_MAX * amount * lit
	return out


## Sky-shader haze, for the optional horizon-weighted tint. Returned separately
## because main.gd pushes sky uniforms from _update_clouds, not the environment
## update.
static func sky_haze_for(hz: Dictionary, night_amount: float = 0.0) -> Dictionary:
	var day := 1.0 - clampf(night_amount, 0.0, 1.0)
	return {
		"haze_color": hz.get("haze_color", Color(0.68, 0.78, 0.94)),
		"haze_strength": clampf(
			float(hz.get("sky_tint_strength", 0.0)), 0.0, 1.0) * day * 0.85,
	}


static func _f(d: Dictionary, key: String, fallback: float) -> float:
	var v := float(d.get(key, fallback))
	return v if is_finite(v) else fallback


## NaN-safe clamp to 0..1. `clampf` does NOT filter NaN — it propagates it — and
## these values feed light energies and shader uniforms where a non-finite value
## hard-hangs the Vulkan driver (main.gd documents this as a whole-desktop
## failure, not just a bad frame). Every 0..1 factor in resolve() goes through
## here; the selftest's NaN sweep exists because three of them originally did not.
static func _clamp01(v: float) -> float:
	if not is_finite(v):
		return 0.0
	return clampf(v, 0.0, 1.0)
