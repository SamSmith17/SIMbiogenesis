class_name DaylightModel
extends RefCounted

## One continuous model of how sunlight and skylight change with solar
## altitude. main.gd reads it for the DirectionalLight sun AND moon (energy +
## colour), the ambient ramp, the vegetation "the beam is gone" signal and the
## glow; `daylight_fraction()` in sky.gdshader mirrors `sky_light()` line for
## line so the sky and the ground darken on ONE curve. Pure and static —
## `core/env/daylight_model_selftest.gd` pins every number below.
##
## Why it exists: sunrise used to switch on like a lightbulb. The sun light
## faded in with smoothstep(-0.1, 0.2, sin alt) — 26 % of noon power, pure
## WHITE, hard shadows, with the disc still 5.7° BELOW the horizon; the sky
## shader went from black to full twilight between -7° and +2°; the ambient
## ramp was still a third of daylight at -12°; and the forest went dark over
## its own 4.6° window. Four curves, none of them the sun's.
##
## Direct beam — Kasten & Young (1989) air mass through the SAME four-term
## clear-sky transmittance `SolarIrradiance.dni_clear_sky_wm2` uses for the
## PV physics, normalised to 1 at the zenith: the light the player sees and
## the watts the panels make follow one atmosphere (pinned). The disc rises
## over -0.9°…-0.2° (refracted upper limb → whole disc). Numbers: 2.5 % of
## noon on the horizon, 31 % at 5°, 52 % at 10°, 85 % at 30°, 97 % at 60°.
##
## Colour — Rayleigh optical depth (Bodhaine et al. 1999, τ ∝ λ^-4.05:
## 0.050 / 0.099 / 0.223 at the R/G/B wavelengths) relative to green, over a
## FRACTION of the excess air mass. The full chromatic depth gives a
## blood-red horizon sun; real low sunlight is largely aerosol-scattered,
## which is far less wavelength-selective. 0.45 lands on ≈2100 K on the
## horizon, ≈3700 K at 5°, ≈4600 K at 10°, neutral by 30° — the measured
## daylight CCT range (Hernández-Andrés, Romero & Lee 2001).
##
## Skylight — horizontal illuminance drops about one decade per 3° of solar
## depression through civil twilight (~400 lux at sunset, ~3 lux at -6°,
## ~0.01 lux at -12°). A fixed-exposure renderer cannot show five decades,
## so the ramp is exp(-0.25 · depression°): half the physical slope in log
## space, i.e. perceptually compressed, with a soft cut at the end of
## astronomical twilight. Above the horizon the diffuse sky climbs from
## 55 % at sunrise to full by 15° (real diffuse-horizontal is ~25 % at
## sunrise; the compression again).

## Diffuse sky brightness at sunrise relative to full day.
const SKY_AT_SUNRISE : float = 0.55
## sin(altitude) at which the diffuse sky reaches full brightness (15°).
const SKY_FULL_SIN_ALT : float = 0.26
## Twilight fall-off per degree of solar depression at twilight_length 1.
const TWILIGHT_K_PER_DEG : float = 0.25
## Soft cut of the residual twilight (degrees of depression, × twilight_length).
const TWILIGHT_CUT_START_DEG : float = 15.0
const TWILIGHT_CUT_END_DEG : float = 21.0
## Disc rise window in sin(altitude): refracted upper limb (-0.9°) → whole disc up (-0.2°).
const RISE_START_SIN : float = -0.0157
const RISE_END_SIN : float = -0.0035
## Rayleigh optical depth at ~650 / 550 / 450 nm (Bodhaine et al. 1999).
const RAYLEIGH_TAU := Vector3( 0.050, 0.099, 0.223 )
## Fraction of the excess air mass the chromatic (Rayleigh-only) depth acts over.
const CHROMA_AIRMASS_FRACTION : float = 0.45
## Multiplier on the normalised beam so the midday look the old "high-sun
## boost" (×1.3 above 53°) produced is preserved; the shape is all transmittance.
const SUN_ZENITH_GAIN : float = 1.3
## Vegetation reads "the beam is gone": 1 below the horizon, 0 once the direct
## fraction passes this (≈5° up).
const VEG_NIGHT_DIRECT_FULL : float = 0.35


## Kasten & Young (1989) relative optical air mass from sin(altitude), clamped
## to [1, 38]. Same formula as SolarIrradiance. Below the horizon it returns
## the HORIZON value: the fit is only defined down to −6.08° and, evaluated
## there with the sine clamped, it shrinks again as the sun sinks (12 at −3°),
## so the beam and its colour wobbled during the disc rise. The path through
## the atmosphere cannot get shorter once the disc is down.
static func air_mass( sin_alt: float ) -> float :
	var s := clampf( sin_alt, 0.0, 1.0 )
	var h_deg := rad_to_deg( asin( s ) )
	var m := 1.0 / ( s + 0.50572 * pow( h_deg + 6.07995, -1.6364 ) )
	return clampf( m, 1.0, 38.0 )


## Four-term clear-sky beam transmittance (Rayleigh, aerosol at the baseline
## AOD, ozone, water vapour) — identical to SolarIrradiance.dni_clear_sky_wm2.
static func _clear_sky_t( m: float ) -> float :
	return exp( -0.0903 * pow( m, 0.84 ) ) * exp( -0.12 * pow( m, 0.75 ) ) \
		* exp( -0.0127 * pow( m, 0.26 ) ) * exp( -0.009 * pow( m, 0.75 ) )


## Beam transmittance relative to the zenith (1 overhead, ≈0.025 on the horizon).
static func transmittance( sin_alt: float ) -> float :
	return _clear_sky_t( air_mass( sin_alt ) ) / _clear_sky_t( 1.0 )


## 0 with the disc below the refracted horizon, 1 once it is wholly up.
static func disc_rise( sin_alt: float ) -> float :
	return smoothstep( RISE_START_SIN, RISE_END_SIN, sin_alt )


## Direct-beam energy relative to an overhead sun — the DirectionalLight ramp.
static func direct_fraction( sin_alt: float ) -> float :
	var rise := disc_rise( sin_alt )
	if rise <= 0.0 :
		return 0.0
	return rise * transmittance( sin_alt )


## Colour of the direct beam (max channel = 1). warmth 0 = white at every
## altitude; 1 = the Rayleigh reddening above; 2 = twice the chromatic depth.
static func direct_color( sin_alt: float, warmth: float = 1.0 ) -> Color :
	var x := ( air_mass( sin_alt ) - 1.0 ) * CHROMA_AIRMASS_FRACTION * maxf( warmth, 0.0 )
	var r := exp( -( RAYLEIGH_TAU.x - RAYLEIGH_TAU.y ) * x )
	var g := 1.0
	var b := exp( -( RAYLEIGH_TAU.z - RAYLEIGH_TAU.y ) * x )
	var mx := maxf( r, maxf( g, b ) )
	return Color( r / mx, g / mx, b / mx, 1.0 )


## Diffuse skylight relative to full day (drives the ambient). MIRRORED by
## daylight_fraction() in sky.gdshader — edit both.
static func sky_light( sin_alt: float, twilight_length: float = 1.0 ) -> float :
	if sin_alt >= 0.0 :
		return lerpf( SKY_AT_SUNRISE, 1.0, smoothstep( 0.0, SKY_FULL_SIN_ALT, sin_alt ) )
	var tl := maxf( twilight_length, 0.05 )
	var d := rad_to_deg( asin( clampf( -sin_alt, 0.0, 1.0 ) ) )
	var k := TWILIGHT_K_PER_DEG / tl
	return SKY_AT_SUNRISE * exp( -k * d ) \
		* ( 1.0 - smoothstep( TWILIGHT_CUT_START_DEG * tl, TWILIGHT_CUT_END_DEG * tl, d ) )


## Envelope of the twilight colours: 1 with the sun on or above the horizon,
## the same exponential fall below it.
static func twilight_palette( sin_alt: float, twilight_length: float = 1.0 ) -> float :
	return minf( sky_light( sin_alt, twilight_length ) / SKY_AT_SUNRISE, 1.0 )


## 0 = full day, 1 = full night; what fog, glow and the sky's night mix read.
static func night_amount( sin_alt: float, twilight_length: float = 1.0 ) -> float :
	return 1.0 - twilight_palette( sin_alt, twilight_length )


## Vegetation's "direct sun is gone" signal (kills the fake sun highlights and
## darkens the canopy): follows the beam instead of a separate 4.6° step.
static func vegetation_night( sin_alt: float ) -> float :
	return 1.0 - smoothstep( 0.0, VEG_NIGHT_DIRECT_FULL, direct_fraction( sin_alt ) )
