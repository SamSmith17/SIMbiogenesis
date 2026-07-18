class_name HeliostatSource
extends RefCounted
## Dual-axis point-focus solar concentrator ("dish" heliostat / solar furnace).
##
## Tracking geometry: an alt-azimuth mount aims the mirror dish's optical axis
## DIRECTLY at the sun in both azimuth and altitude (see
## gameplay/heliostat_tracker.gd). Unlike the single-axis parabolic trough
## (csp_trough_source.gd), whose fixed E-W axis suffers a large morning/evening
## cosine loss, a two-axis tracker keeps the beam at normal incidence whenever
## the sun is up, so cos(incidence) ≈ 1 all day. The whole `mirror_area` of
## collimated beam is reflected onto a small receiver aperture (the modelled
## "concentrator area / focal point box"), giving a high geometric
## concentration ratio C = mirror_area / aperture_area.
##
## Focal temperature (the headline number): the receiver reaches a STAGNATION
## temperature where the absorbed concentrated power equals the receiver's heat
## losses. Modelled as a cavity receiver — radiative loss out the aperture
## (Stefan-Boltzmann, ε σ A_ap (T⁴ − T_amb⁴)) plus convective loss off the box
## exterior (h A_ext (T − T_amb)). Solving that balance for T gives the focal
## stagnation temperature; with a ~77× concentration on a 19.36 m² dish under
## ~1 kW/m² DNI this lands in the ~700–800 °C solar-furnace range.
##
## Useful heat output: the thermal power delivered to a working fluid held at a
## nominal operating temperature is the absorbed power minus the receiver
## losses AT that operating temperature, times a heat-exchanger efficiency —
## then converted to a water→steam boil-off rate with the same 1-atm energy
## budget as CspTroughSource (sensible heat to 100 °C + latent heat).
##
## DNI reuses CspTroughSource.dni_wm2 (Kasten-Young clear sky, cloud/clearness
## attenuated) so the two concentrator families share one atmosphere model.

const _CSP := preload("res://power_system/sources/csp_trough_source.gd")

## Stefan-Boltzmann constant (W·m⁻²·K⁻⁴).
const SIGMA := 5.670374419e-8
const CP_WATER_KJ_PER_KG_K := 4.186
const H_FG_KJ_PER_KG := 2257.0
const BOILING_POINT_C := 100.0
const WATER_DENSITY_KG_PER_L := 1.0


## Receiver heat loss (W) at absolute temperature `t_k`: cavity radiation out the
## aperture + convection off the exposed box exterior.
static func receiver_loss_w(t_k: float, emissivity: float, aperture_area_m2: float,
		conv_coeff: float, ext_area_m2: float, t_amb_k: float) -> float:
	var t4 := t_k * t_k * t_k * t_k
	var ta4 := t_amb_k * t_amb_k * t_amb_k * t_amb_k
	var rad := emissivity * SIGMA * aperture_area_m2 * (t4 - ta4)
	var conv := conv_coeff * ext_area_m2 * (t_k - t_amb_k)
	return rad + conv


## Stagnation temperature (K): the temperature at which receiver_loss_w equals
## the absorbed power `q_abs_w`. Solved with a few Newton-Raphson steps on the
## monotonically-increasing loss(T); falls back to ambient when no power lands.
static func stagnation_temp_k(q_abs_w: float, emissivity: float, aperture_area_m2: float,
		conv_coeff: float, ext_area_m2: float, t_amb_k: float) -> float:
	if q_abs_w <= 0.0:
		return t_amb_k
	var t := t_amb_k + 50.0
	for _i in 40:
		var loss := receiver_loss_w(t, emissivity, aperture_area_m2, conv_coeff, ext_area_m2, t_amb_k)
		var f := loss - q_abs_w
		# d(loss)/dT = 4 ε σ A_ap T³ + h A_ext
		var d := 4.0 * emissivity * SIGMA * aperture_area_m2 * t * t * t + conv_coeff * ext_area_m2
		if d <= 1e-9:
			break
		var t_next := t - f / d
		if t_next < t_amb_k:
			t_next = t_amb_k + (t - t_amb_k) * 0.5   # keep the bracket above ambient
		if absf(t_next - t) < 0.01:
			t = t_next
			break
		t = t_next
	return maxf(t, t_amb_k)


## Full instantaneous performance for one heliostat given its graph specs + live
## sun position + weather. Returns a telemetry Dictionary the graph tick writes
## back onto specs and uses to drive the water→steam port rates.
static func simulate(specs: Dictionary, sun_az_deg: float, sun_el_deg: float,
		weather: Dictionary) -> Dictionary:
	var mirror_area := maxf(float(specs.get("mirror_area_m2", 19.36)), 0.1)
	var box := maxf(float(specs.get("focal_box_size_m", 0.5)), 0.02)
	var opt_eff := clampf(float(specs.get("optical_efficiency", 0.80)), 0.0, 1.0)
	var absorptivity := clampf(float(specs.get("receiver_absorptivity", 0.95)), 0.0, 1.0)
	var emissivity := clampf(float(specs.get("receiver_emissivity", 0.90)), 0.01, 1.0)
	var conv_coeff := maxf(float(specs.get("conv_coeff_w_m2k", 10.0)), 0.0)
	var op_temp_c := clampf(float(specs.get("operating_temp_c", 250.0)), 20.0, 3000.0)
	var therm_eff := clampf(float(specs.get("thermal_efficiency", 0.85)), 0.0, 1.0)
	var feedwater_c := clampf(float(specs.get("feedwater_temp_c", 20.0)), 0.0, 99.0)

	# Perfect two-axis pointing → normal incidence whenever the sun is up.
	var cos_inc := 1.0 if sun_el_deg > 0.0 else 0.0
	var dni := _CSP.dni_wm2(sun_el_deg, weather)

	var aperture_area := box * box            # one receiver face, toward the dish
	var ext_area := 5.0 * box * box           # remaining box exterior (convective)
	var concentration := mirror_area / maxf(aperture_area, 1e-4)

	var q_in_w := dni * cos_inc * mirror_area * opt_eff     # beam power onto aperture
	var q_abs_w := q_in_w * absorptivity                    # absorbed by receiver
	var flux_kw_m2 := (q_in_w / maxf(aperture_area, 1e-4)) / 1000.0

	var t_amb_k := float(weather.get("temp", 25.0)) + 273.15
	var t_stag_k := stagnation_temp_k(q_abs_w, emissivity, aperture_area, conv_coeff, ext_area, t_amb_k)
	var focal_temp_c := t_stag_k - 273.15

	# Useful heat = absorbed minus receiver loss at the operating temperature
	# (never above stagnation), delivered through the boiler heat exchanger.
	var t_op_k := minf(op_temp_c + 273.15, t_stag_k)
	var loss_op := receiver_loss_w(t_op_k, emissivity, aperture_area, conv_coeff, ext_area, t_amb_k)
	var thermal_kw := maxf(q_abs_w - loss_op, 0.0) * therm_eff / 1000.0

	var energy_per_kg := CP_WATER_KJ_PER_KG_K * (BOILING_POINT_C - feedwater_c) + H_FG_KJ_PER_KG
	var mass_flow_kg_s := thermal_kw / maxf(energy_per_kg, 1.0)
	var steam_kg_h := mass_flow_kg_s * 3600.0
	var water_lph := steam_kg_h / WATER_DENSITY_KG_PER_L

	return {
		"cos_incidence": cos_inc,
		"dni_wm2": dni,
		"incident_kw": q_in_w / 1000.0,
		"absorbed_kw": q_abs_w / 1000.0,
		"concentration_ratio": concentration,
		"focal_flux_kw_m2": flux_kw_m2,
		"focal_temp_c": focal_temp_c,
		"thermal_output_kw": thermal_kw,
		"steam_kg_h": steam_kg_h,
		"water_lph": water_lph,
	}
