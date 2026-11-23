class_name SdfgiPolicy
extends RefCounted

## Outdoor SDFGI calibration, cascade geometry, outside-sky matching and
## survey-altitude handover policy.
##
## Why the giant rectangular "spotlight" happened before:
##   1. Inside vs. outside replacement mismatch (`scene_forward_clustered.glsl`):
##      In Godot 4 Forward+, SDFGI is NOT additive — it replaces fallback ambient:
##        ambient_final = mix(L_outside, L_sdfgi, cascade_blend)
##      where:
##        L_outside = ambient_light_energy * mix(ambient_color_lin, E_sky, sky_contrib)
##        L_sdfgi   = sdfgi_energy * (E_sky_occluded + E_bounce)
##      In `generated_location.tscn`, `ambient_light_color` is BLACK `(0,0,0)` and
##      `ambient_light_sky_contribution` defaults to `0.15` (or `0.0` if turned down),
##      giving `L_outside = 0.045 * E_sky` (or `0`), while `sdfgi_energy = 1.0` gave
##      `L_sdfgi = 1.0 * (E_sky + E_bounce)` — a 22×+ jump across a sharp box edge!
##   2. Indoor-sized default cascades: 4 cascades × 0.2 m cell × 50 % Y-scale
##      covered only a 204.8 m horizontal square and ±51.2 m vertically, placing
##      hard axis-aligned borders across the middle of drone views and lifting the
##      cascade slab off the terrain above 51 m AGL.
##
## How this policy fixes both while keeping rich SDFGI lighting:
##   - Sets `sdfgi_energy` to a natural outdoor GI baseline (`DAY_SDFGI_ENERGY = 0.28`
##     × `sdfgi_energy_mult`, tapered gently against the night star-map floor so
##     midnight stays dark while campfires/lamps still bounce GI).
##   - While SDFGI is enabled by the player, matches the outside fallback to the
##     SAME sky cubemap (`ambient_light_sky_contribution = 1.0`,
##     `ambient_light_energy = sdfgi_energy * (1 + sun_bounce_frac)`), so `L_outside`
##     and `L_sdfgi` have the SAME luminance and sky hue on open terrain across
##     noon, sunset, dusk and night (`mix(A, B, blend) ≈ A` everywhere on open ground),
##     while buildings, trees, overhangs and interiors still get full 3D sky
##     occlusion (`sdfgi_use_occlusion = true`) and directional sunlight bounce.
##   - Expands cascades to 1.23 km (High) / 2.05 km (Ultra) with 75–100 % Y-scale.
##   - Above survey drone altitude (`suspend_agl_m`, well below the cascade's
##     vertical half-extent, with `HYSTERESIS_M` deadband), suspends
##     `env.sdfgi_enabled = false` while keeping the matched `Environment` sky
##     ambient active — zero square cascade, zero brightness shift on handover,
##     and zero SDFGI GPU cost at high altitude.
##
## Pure and static — pinned offline by `core/env/sdfgi_policy_selftest.gd`.

## Natural outdoor SDFGI probe gain at noon (`sdfgi_energy_mult = 1.0`): gives
## clear sky-dome shadow fill + warm wall bounce without neon-teal over-saturation.
const DAY_SDFGI_ENERGY : float = 0.18
## Baseline `main.gd` daytime `ambient_light_energy` reference (`day_ambient = 0.30`).
const DAY_AMBIENT_REF : float = 0.30
## Empirical ratio between Godot 4's SDFGI hemispherical probe irradiance and
## `Environment` `cubemap_ambient` (`MAX_ROUGHNESS_LOD` radiance cubemap) on open
## horizontal terrain (~2.2× before sun bounce, ~2.5× with noon sun bounce).
const SDFGI_TO_CUBEMAP_RATIO : float = 2.25
## Fraction of extra open-ground irradiance from bounced direct sunlight at high sun.
const SUN_BOUNCE_OPEN_FRAC : float = 0.12
## Altitude deadband (metres) preventing on/off chatter when hovering near handover.
const HYSTERESIS_M : float = 25.0


## Cascade and survey-handover parameters for `RenderProfile.QUALITY_*` (0..3).
## Unknown indices fall back to HIGH, matching `RenderProfile.graphics_profile`.
static func cascade_profile( quality: int ) -> Dictionary :
	match quality :
		RenderProfile.QUALITY_LOW :
			return {
				"cascades": 4,
				"min_cell_size": 0.45,
				"y_scale": Environment.SDFGI_Y_SCALE_75_PERCENT,
				"bounce_feedback": 0.30,
				"use_occlusion": true,
				"read_sky_light": true,
				"suspend_agl_m": 135.0,
			}
		RenderProfile.QUALITY_MEDIUM :
			return {
				"cascades": 5,
				"min_cell_size": 0.38,
				"y_scale": Environment.SDFGI_Y_SCALE_75_PERCENT,
				"bounce_feedback": 0.32,
				"use_occlusion": true,
				"read_sky_light": true,
				"suspend_agl_m": 175.0,
			}
		RenderProfile.QUALITY_ULTRA :
			return {
				"cascades": 7,
				"min_cell_size": 0.25,
				"y_scale": Environment.SDFGI_Y_SCALE_100_PERCENT,
				"bounce_feedback": 0.38,
				"use_occlusion": true,
				"read_sky_light": true,
				"suspend_agl_m": 260.0,
			}
	# QUALITY_HIGH (2) and fallback: 0.30 m inner detail + 1,228.8 m (±614.4 m) reach.
	return {
		"cascades": 6,
		"min_cell_size": 0.30,
		"y_scale": Environment.SDFGI_Y_SCALE_75_PERCENT,
		"bounce_feedback": 0.35,
		"use_occlusion": true,
		"read_sky_light": true,
		"suspend_agl_m": 210.0,
	}


## Matches Godot's `Environment.sdfgi_max_distance` (`min_cell_size * 64 * 2^cascades`,
## the full width of the outermost cascade box in metres).
static func max_distance_m( profile: Dictionary ) -> float :
	var cascades := maxi( int( profile.get( "cascades", 6 ) ), 1 )
	var cell := maxf( float( profile.get( "min_cell_size", 0.30 ) ), 0.01 )
	return cell * 64.0 * pow( 2.0, float( cascades ) )


## Horizontal half-extent (camera to outer cascade face, in metres) = `0.5 * sdfgi_max_distance`.
static func horizontal_half_extent_m( profile: Dictionary ) -> float :
	return 0.5 * max_distance_m( profile )


## Vertical multiplier for an `Environment.SDFGIYScale` enum value.
static func y_scale_factor( y_scale: int ) -> float :
	match y_scale :
		Environment.SDFGI_Y_SCALE_50_PERCENT :
			return 0.50
		Environment.SDFGI_Y_SCALE_75_PERCENT :
			return 0.75
		Environment.SDFGI_Y_SCALE_100_PERCENT :
			return 1.00
	return 0.75


## Vertical half-extent (metres above/below the camera) of the outer cascade.
## Exceeds `suspend_agl_m` in every preset so the cascade never lifts its bottom
## slab off the terrain before survey handover suspends SDFGI cleanly.
static func vertical_half_extent_m( profile: Dictionary ) -> float :
	return horizontal_half_extent_m( profile ) * y_scale_factor( int( profile.get( "y_scale", Environment.SDFGI_Y_SCALE_75_PERCENT ) ) )


## Hysteretic survey-altitude gate: suspends SDFGI once camera climbs past
## `suspend_agl_m`, and re-enables once camera descends below `suspend_agl_m - HYSTERESIS_M`.
static func should_enable_at_agl( agl_m: float, suspend_agl_m: float, currently_enabled: bool ) -> bool :
	if not is_finite( agl_m ) :
		return true
	var hi := maxf( suspend_agl_m, 40.0 )
	var lo := maxf( hi - HYSTERESIS_M, 20.0 )
	if currently_enabled :
		return agl_m < hi
	return agl_m <= lo


## Calibrated `Environment.sdfgi_energy` for a given `sky_light` (`DaylightModel.sky_light`),
## `moon_ambient` (`0..0.008`), and user `sdfgi_energy_mult` (`SDFGI strength ×`).
## Scales smoothly with `pow(sky_light, 0.70)` through sunset and twilight so the
## artistic horizon glare in `sky.gdshader` does not keep the 1–2 km SDFGI box
## lit at daytime brightness while distant hills sink into dark dusk haze.
static func calibrated_energy(
		sky_light: float,
		moon_ambient: float = 0.0,
		user_strength_mult: float = 1.0,
		env_mod_mult: float = 1.0 ) -> float :
	var strength := clampf( user_strength_mult, 0.0, 4.0 ) if is_finite( user_strength_mult ) else 1.0
	var mod := clampf( env_mod_mult, 0.0, 4.0 ) if is_finite( env_mod_mult ) else 1.0
	if strength <= 0.0 or mod <= 0.0 :
		return 0.0
	var sky_c := clampf( sky_light, 0.0, 1.0 ) if is_finite( sky_light ) else 1.0
	var moon_c := maxf( moon_ambient, 0.0 ) if is_finite( moon_ambient ) else 0.0
	var moon_lift := clampf( moon_c / 0.008, 0.0, 1.0 )
	var night_gain := lerpf( 0.08, 0.22, moon_lift )
	var day_curve := pow( sky_c, 0.70 )
	var taper := lerpf( night_gain, 1.0, day_curve )
	return DAY_SDFGI_ENERGY * taper * mod * strength


## Matching outside `Environment.ambient_light_energy` (with `ambient_light_sky_contribution = 1.0`)
## while SDFGI is enabled by the player: accounts for `SDFGI_TO_CUBEMAP_RATIO`
## (~2.25× hemispherical probe irradiance vs `cubemap_ambient`) plus open-field
## sun bounce so open ground outside the cascade — and the whole landscape above
## survey-drone handover — matches open ground inside the cascade.
static func matched_sky_ambient_energy( sdfgi_energy: float, sky_light: float ) -> float :
	if not is_finite( sdfgi_energy ) or sdfgi_energy <= 0.0 :
		return 0.0
	var sky_c := clampf( sky_light, 0.0, 1.0 ) if is_finite( sky_light ) else 1.0
	var sun_up := smoothstep( 0.55, 0.95, sky_c )
	return sdfgi_energy * SDFGI_TO_CUBEMAP_RATIO * ( 1.0 + SUN_BOUNCE_OPEN_FRAC * sun_up )


## Estimate of the sky irradiance cubemap's mean upper-hemisphere linear RGB at
## the given `sky_light` (`DaylightModel.sky_light`) and `night_amount`.
static func estimated_sky_irradiance( sky_light: float, night_amount: float, fog_light_color: Color ) -> Vector3 :
	var sky_c := clampf( sky_light, 0.0, 1.0 ) if is_finite( sky_light ) else 1.0
	var night_c := clampf( night_amount, 0.0, 1.0 ) if is_finite( night_amount ) else 0.0
	# Matches Godot's `MAX_ROUGHNESS_LOD` radiance_cubemap scale (~0.25 mean at noon,
	# i.e. 1 / SDFGI_TO_CUBEMAP_RATIO of full hemisphere probe sum) so multiplying by
	# `env.ambient_light_energy` lands on the exact same brightness as built-in sky ambient.
	var day_sky := Vector3( 0.20, 0.25, 0.33 )
	var fog_vec := Vector3( fog_light_color.r, fog_light_color.g, fog_light_color.b )
	var day_tinted := day_sky.lerp( fog_vec * 0.55, 0.35 ) * sky_c
	var night_sky := Vector3( 0.005, 0.007, 0.012 )
	return day_tinted.lerp( night_sky, night_c * 0.85 ) + night_sky * night_c * 0.15


## Custom sky/ground ambient RGB (`terrain_sky_ambient` global shader uniform)
## used by `terrain_detail_no_sdfgi.gdshader` when "SDFGI on terrain" is off.
static func terrain_custom_ambient_color(
		final_ambient_energy: float,
		sky_light: float,
		night_amount: float,
		fog_light_color: Color,
		sky_contrib: float,
		ambient_color: Color = Color.BLACK ) -> Vector3 :
	var e := maxf( final_ambient_energy, 0.0 ) if is_finite( final_ambient_energy ) else 0.0
	if e <= 0.0 :
		return Vector3.ZERO
	var sc := clampf( sky_contrib, 0.0, 1.0 ) if is_finite( sky_contrib ) else 0.15
	var lin_c := ambient_color.srgb_to_linear()
	var amb_vec := Vector3( lin_c.r, lin_c.g, lin_c.b )
	var sky_irr := estimated_sky_irradiance( sky_light, night_amount, fog_light_color )
	return amb_vec.lerp( sky_irr, sc ) * e


## Write cascade parameters onto `env` ONLY when they actually changed — writing
## `sdfgi_cascades`, `sdfgi_min_cell_size` or `sdfgi_y_scale` unconditionally on
## every 20 Hz environment tick would reallocate/clear Godot's SDFGI cascade
## textures and cause continuous re-baking flicker.
static func apply_cascade_profile( env: Environment, quality: int ) -> Dictionary :
	var p := cascade_profile( quality )
	if env == null :
		return p
	var want_cascades := int( p[ "cascades" ] )
	if env.sdfgi_cascades != want_cascades :
		env.sdfgi_cascades = want_cascades
	var want_cell := float( p[ "min_cell_size" ] )
	if not is_equal_approx( env.sdfgi_min_cell_size, want_cell ) :
		env.sdfgi_min_cell_size = want_cell
	var want_y := int( p[ "y_scale" ] ) as Environment.SDFGIYScale
	if env.sdfgi_y_scale != want_y :
		env.sdfgi_y_scale = want_y
	var want_bounce := float( p[ "bounce_feedback" ] )
	if not is_equal_approx( env.sdfgi_bounce_feedback, want_bounce ) :
		env.sdfgi_bounce_feedback = want_bounce
	var want_occ := bool( p[ "use_occlusion" ] )
	if env.sdfgi_use_occlusion != want_occ :
		env.sdfgi_use_occlusion = want_occ
	var want_sky := bool( p[ "read_sky_light" ] )
	if env.sdfgi_read_sky_light != want_sky :
		env.sdfgi_read_sky_light = want_sky
	return p
