class_name CspTroughSource
extends RefCounted
## Single-axis parabolic-trough concentrating solar power (CSP) physics.
##
## Tracking geometry: horizontal single-axis tracker whose pivot axis runs
## EAST-WEST, so the trough's long axis lies E-W and the aperture faces the
## equator (south in the northern hemisphere, north in the southern) while
## tilting up/down through the day to follow the sun's altitude. This is the
## classic "E-W horizontal axis" configuration (Duffie & Beckman, "Solar
## Engineering of Thermal Processes", 4th ed., §1.7 / eq. 1.7.2a): it achieves
## ZERO incidence at every solar noon (the sun sits in the N-S meridian plane,
## which is perpendicular to the E-W axis) at the cost of poor morning/evening
## performance (the axis cannot swing east or west to face the low sun).
##
## For ANY 1-DOF tracker whose rotation axis is unit vector `a`, the best
## achievable cos(incidence) is the length of the sun vector's projection onto
## the plane perpendicular to `a`, i.e. sqrt(1 - (S . a)^2) — the axis-aligned
## component of the sun direction can never be recovered by rotating about that
## same axis. This engine is Y-up with -Z = north, so the sun unit vector is
##     S = (cos(el)sin(az), sin(el), -cos(el)cos(az))       [east, up, +Z=south]
## (az measured 0=N,90=E,180=S,270=W; el = elevation above horizon). With the
## pivot axis a = east = (1,0,0):
##     S . a = cos(el)sin(az)
##     cos(theta_i) = sqrt(1 - (cos(el)sin(az))^2)
## This is 1 (perfect) when the sun is due south/north (sin(az)=0 → noon) or
## straight overhead, and drops toward 0 as the sun approaches due east/west
## low on the horizon (az=90/270) — the E-W tracker's well-documented sunrise/
## sunset cosine loss.
##
## Tracking angle: the signed tilt of the aperture normal away from vertical,
## measured toward south (+) / north (-), that keeps the normal aligned with
## the sun's projection into the N-S meridian plane:
##     theta = atan2(S_south, S_up) = atan2(-cos(el)cos(az), sin(el))
## At solar noon this equals (90° - elevation) toward the equator; it is zero
## when the sun crosses due east/west (the meridian projection is flat), and
## goes negative (tilts north) whenever the sun passes north of the zenith
## (tropical summer / southern hemisphere) — so the SAME formula is correct in
## both hemispheres with no special-casing.
##
## End losses (aperture area lost off the ends of a finite-length trough,
## per Duffie & Beckman / NREL SAM's physical trough model):
##     end_loss_length = focal_length_m * tan(theta_i)
## expressed as a fraction of module_length_m, clamped to [0, 1].
##
## Water -> steam: mass-conserving boil-off at ~1 atm. Energy per kg =
## sensible heat to 100 C (cp_water = 4.186 kJ/kg-K) + latent heat of
## vaporization (h_fg = 2257 kJ/kg — steam tables at 100 C / 1 atm).

const SOLAR_CONSTANT := 1361.0
const CP_WATER_KJ_PER_KG_K := 4.186
const H_FG_KJ_PER_KG := 2257.0
const BOILING_POINT_C := 100.0
const WATER_DENSITY_KG_PER_L := 1.0

## World-space pivot axis of the single-axis tracker: east (with -Z = north,
## this makes the trough's long axis run east-west). Shared with
## CspTroughTracker so the 3D model's rotation stays in lock-step with the
## physics — one source of truth for "which way the axis points".
const TRACKING_AXIS := Vector3(1.0, 0.0, 0.0)


## Signed tracking angle (degrees) of the aperture normal from vertical,
## + toward south / − toward north, clamped to the mechanical stop. This is the
## tilt an E-W-horizontal-axis tracker adopts to keep its aperture normal in
## the N-S meridian plane containing the sun (Duffie & Beckman §1.7).
static func tracking_angle_deg(sun_az_deg: float, sun_el_deg: float,
		max_angle_deg: float = 110.0) -> float:
	if sun_el_deg <= 0.0:
		return 0.0
	var el := deg_to_rad(sun_el_deg)
	var az := deg_to_rad(sun_az_deg)
	var s_south := -cos(el) * cos(az)   # +Z (south) component of the sun vector
	var s_up := sin(el)                 # +Y (up) component
	var theta := atan2(s_south, s_up)
	return clampf(rad_to_deg(theta), -max_angle_deg, max_angle_deg)


## Cosine of the residual incidence angle for a horizontal E-W-axis tracker
## (see class doc). 0 when the sun is below the horizon.
static func cos_incidence(sun_az_deg: float, sun_el_deg: float) -> float:
	if sun_el_deg <= 0.0:
		return 0.0
	var el := deg_to_rad(sun_el_deg)
	var az := deg_to_rad(sun_az_deg)
	var sun_east := cos(el) * sin(az)   # E-W component (the axis-aligned part)
	return sqrt(clampf(1.0 - sun_east * sun_east, 0.0, 1.0))


## Given a mesh's REST-pose aperture normal and its (world) pivot axis, both
## expressed in the same space, returns the rest pose's angular offset (rad)
## from "pointing straight up" in the same signed convention as
## `tracking_angle_deg` (+ toward the tilt direction produced by a positive
## rotation about `axis`). The normal is projected onto the plane perpendicular
## to `axis` first (the axial component is un-recoverable rotation and dropped),
## so callers whose authored rest pose ISN'T exactly "straight up" (e.g. an
## arbitrary export pose) can do `mechanical_rotation = ideal_theta - rest_offset`
## and still land exactly on the ideal tracking angle — see csp_trough_tracker.gd
## for the empirical derivation/verification of this identity.
static func tracking_offset_from_normal(normal_world: Vector3, axis_world: Vector3) -> float:
	var axis := axis_world.normalized()
	# In-plane basis: `up_ref` (vertical, projected perpendicular to the axis)
	# and `tilt_dir` (the direction a +rotation about the axis tilts the normal).
	var up_ref := Vector3.UP - axis * Vector3.UP.dot(axis)
	var tilt_dir := axis.cross(Vector3.UP)
	if up_ref.length_squared() < 1e-6 or tilt_dir.length_squared() < 1e-6:
		return 0.0
	up_ref = up_ref.normalized()
	tilt_dir = tilt_dir.normalized()
	var perp := normal_world - axis * normal_world.dot(axis)
	if perp.length_squared() < 1e-6:
		return 0.0
	return atan2(perp.dot(tilt_dir), perp.dot(up_ref))


## Direct normal irradiance (W/m²): clear-sky Kasten-Young model
## (SolarIrradiance.dni_clear_sky_wm2), attenuated by real cloud cover when
## available. WeatherService has no measured DNI, so cloud is folded in via
## an approximate clearness-index correction — direct beam attenuates faster
## than diffuse under cloud (Erbs 1982 trend) — approximated here as kt²,
## not a literal DNI/DHI decomposition.
## Aerosol enters through the SAME clear-sky helpers the rest of the project
## uses, so a concentrating collector needs no attenuation logic of its own.
## Its response is nonetheless far harsher than flat-plate PV's, and correctly
## so: a trough can only use the DIRECT beam, and beam is exactly what smoke and
## dust destroy while leaving diffuse light behind. A hazy day that costs a
## rooftop array a third of its yield can take a trough to almost nothing.
static func dni_wm2(sun_el_deg: float, weather: Dictionary) -> float:
	if sun_el_deg <= 0.0:
		return 0.0
	var aod := float(weather.get("aod", SolarIrradiance.AOD_BASELINE))
	if not is_finite(aod):
		aod = SolarIrradiance.AOD_BASELINE
	var dni_clear := SolarIrradiance.dni_clear_sky_wm2(sun_el_deg, aod)
	if bool(weather.get("has_real", false)):
		var sin_el := sin(deg_to_rad(sun_el_deg))
		var ghi_clear := dni_clear * sin_el \
			+ SolarIrradiance.dhi_clear_sky_wm2(sun_el_deg, dni_clear, aod)
		var ghi_measured := float(weather.get("ghi", 0.0))
		# Measured GHI carries only climatological aerosol, so scale it the same
		# way SolarIrradiance.ghi_wm2_at_calendar does before forming kt — else
		# the clearness index reads high and cancels the attenuation applied to
		# dni_clear above.
		ghi_measured *= SolarIrradiance.aerosol_ghi_factor(sun_el_deg, aod)
		var kt := clampf(ghi_measured / maxf(ghi_clear, 1.0), 0.0, 1.15)
		return dni_clear * clampf(kt * kt, 0.0, 1.0)
	var cloud := clampf(float(weather.get("cloud", 0.0)), 0.0, 1.0)
	return dni_clear * (1.0 - cloud * 0.85)


## End-loss fraction of the aperture lost off the ends of a finite module
## (see class doc). 0 at normal incidence, approaches 1 near grazing.
static func end_loss_frac(cos_inc: float, focal_length_m: float, module_length_m: float) -> float:
	if module_length_m <= 0.01:
		return 0.0
	var theta_i := acos(clampf(cos_inc, 0.0, 1.0))
	return clampf(focal_length_m * tan(theta_i) / module_length_m, 0.0, 1.0)


## Full instantaneous performance of one trough given its graph specs + live
## sun position + weather. Returns a Dictionary the graph tick writes onto
## specs as telemetry and uses to drive the water-in / steam-out port rates.
static func simulate(specs: Dictionary, sun_az_deg: float, sun_el_deg: float,
		weather: Dictionary) -> Dictionary:
	var max_angle := float(specs.get("max_tracking_angle_deg", 110.0))
	var track_deg := tracking_angle_deg(sun_az_deg, sun_el_deg, max_angle)
	var cos_inc := cos_incidence(sun_az_deg, sun_el_deg)
	var dni := dni_wm2(sun_el_deg, weather)

	var aperture_w := maxf(float(specs.get("aperture_width_m", 5.0)), 0.1)
	var module_len := maxf(float(specs.get("module_length_m", 12.0)), 0.5)
	var focal_len := maxf(float(specs.get("focal_length_m", 1.7)), 0.05)
	var opt_eff := clampf(float(specs.get("optical_efficiency", 0.75)), 0.0, 1.0)
	var therm_eff := clampf(float(specs.get("thermal_efficiency", 0.85)), 0.0, 1.0)
	var feedwater_c := clampf(float(specs.get("feedwater_temp_c", 20.0)), 0.0, 99.0)

	var loss_frac := end_loss_frac(cos_inc, focal_len, module_len)
	var effective_area := aperture_w * module_len * (1.0 - loss_frac)
	var thermal_kw := maxf(dni * cos_inc * effective_area * opt_eff * therm_eff / 1000.0, 0.0)

	var energy_per_kg := CP_WATER_KJ_PER_KG_K * (BOILING_POINT_C - feedwater_c) + H_FG_KJ_PER_KG
	var mass_flow_kg_s := thermal_kw / maxf(energy_per_kg, 1.0)
	var steam_kg_h := mass_flow_kg_s * 3600.0
	var water_lph := steam_kg_h / WATER_DENSITY_KG_PER_L

	return {
		"tracking_angle_deg": track_deg,
		"cos_incidence": cos_inc,
		"dni_wm2": dni,
		"end_loss_frac": loss_frac,
		"effective_area_m2": effective_area,
		"thermal_output_kw": thermal_kw,
		"steam_kg_h": steam_kg_h,
		"water_lph": water_lph,
	}
