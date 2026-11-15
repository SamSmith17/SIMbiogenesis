class_name GreenhouseClimate
extends RefCounted

## A greenhouse's climate, lumped (pure, no autoloads):
##  - the AIR (temperature + humidity ratio) has almost no heat capacity next
##    to what it touches, so it is solved each step from the balance of
##    everything coupled to it (quasi-steady, iterated for the
##    temperature-dependent vents, transpiration and condensation);
##  - three THERMAL MASSES carry the time: the water barrels, the bed soil
##    (top 0.3 m), and the structure (floor slab, opaque walls, the earth
##    against a sunk / bermed house), each stepped explicitly (their time
##    constants are hours to days; steps are at most 15 minutes).
## Fluxes:
##  - sun through each glazing face: PvLabShading.poa per face (orientation
##    bins), beam × the glazing's τ (Fresnel falloff in the IAM), diffuse ×
##    τ_diffuse, × (1 − shade cloth) in its months; split onto the canopy,
##    the paths, the barrels and the back wall by the area each presents;
##  - conduction through the skin, U × A × ΔT, U raised with wind (ASHRAE
##    Fundamentals ch. 26: the outside film);
##  - long-wave from the floor to the sky through glazing that passes thermal
##    IR (τ_lw: polyethylene), the sky at the Berdahl & Martin (1984)
##    clear-sky emissivity raised toward 1 by cloud;
##  - the ground below a sunk floor and behind earth walls at the
##    Kusuda–Achenbach temperature (EarthTemperature.ground_c), 1 m of soil
##    away (k = 1.2 W/m K, moist soil — estimate);
##  - air exchange: infiltration (ACH by glazing), vents (stack + wind,
##    ASHRAE Fundamentals ch. 16: Q_stack = Cd A_eff sqrt(2 g H ΔT / T),
##    Q_wind = Cw A v, combined in quadrature), exhaust fans;
##  - crop transpiration: Penman–Monteith on the canopy with greenhouse
##    resistances after Stanghellini (1987): r_b ≈ 200 s/m in still air,
##    stomata from ~100 s/m in light to ~1000 s/m in the dark;
##  - condensation on the glazing when its inside surface is below the dew
##    point (Lewis analogy h_m = h / (ρ c_p));
##  - the heater, the grow lights (all their watts end as heat), an unvented
##    propane heater's water vapour.
## The energy ledger closes exactly (selftest): in = sun + heater + lights +
## ground; out = skin + long-wave + ventilation + latent; Δ stored = masses.

const SIGMA := 5.670374419e-8
const RHO_AIR := 1.2
const CP_AIR := 1006.0
const LAMBDA := 2.45e6
const CP_WATER := 4186.0
const P_ATM_KPA := 101.325
const G := 9.81

## Inside film coefficients, W/m² K (natural convection + linearised
## radiation exchange between inside surfaces).
const H_SOIL := 6.0
const H_FLOOR := 5.0
const H_WALL := 4.0
const H_BARREL := 7.0
const H_IN_GLAZING := 6.0
const SOIL_DEPTH_M := 0.3
const SOIL_VOL_HEAT := 2.0e6
const FLOOR_DEPTH_M := 0.1
const K_SOIL := 1.2
const GROUND_PATH_M := 1.0
const PAR_FRACTION := 0.45
const UMOL_PER_J_PAR := 4.57
## Vents and infiltration.
const CD := 0.6
const CW := 0.25
const ACH_BASE := {"tarp_pe": 0.75, "polycarb_6": 1.0, "polycarb_4": 1.2, "pmma_4": 1.5, "pmma_6": 1.2}
## Shares of the transmitted sun reflected back out (canopy and floor albedo).
const REFLECT_OUT := 0.12
const ABSORB_CANOPY := 0.85
const ABSORB_FLOOR := 0.7
const ABSORB_BARREL := {"black": 0.92, "blue": 0.6}
const ABSORB_WALL := 0.7
const MAX_SUB_H := 0.25


## Everything the steps need, worked out once from a solved design.
## opts: {yaw_deg (0: +Z to the south), monthly_c: [12 monthly mean °C]}.
static func model(d: Dictionary, opts: Dictionary = {}) -> Dictionary:
	var s: Dictionary = d["spec"]
	var fr: Dictionary = d["frame"]
	var st: Dictionary = d["stats"]
	var yaw := deg_to_rad(float(opts.get("yaw_deg", 0.0)))
	var rot := Basis(Vector3.UP, yaw)
	var bins := {}
	var ua_glazing := 0.0
	var ua_opaque := 0.0
	var a_glazed := 0.0
	var tau_lw_a := 0.0
	var ach_w := 0.0
	var a_earth := 0.0
	var earth_depth_a := 0.0
	var cap_walls := 0.0
	var a_back := 0.0
	var a_opaque := 0.0
	for f in fr["faces"]:
		var fd: Dictionary = f
		var a := float(fd["area"])
		if a <= 0.0:
			continue
		match str(fd["kind"]):
			"earth":
				a_earth += a
				earth_depth_a += a * float(fd["depth_m"])
				var wl := GreenhouseMaterials.wall(str(fd["material"]))
				cap_walls += a * float(wl["cap_kj_m2k"]) * 1000.0
				continue
			"door":
				ua_opaque += a * 3.0
				continue
		if not bool(fd["glazed"]):
			var w := GreenhouseMaterials.wall(str(fd["material"]))
			ua_opaque += a * float(w["u"])
			cap_walls += a * float(w["cap_kj_m2k"]) * 1000.0
			a_opaque += a
			if str(fd["kind"]) == "back":
				a_back += a
			continue
		var g := GreenhouseMaterials.glazing(str(fd["material"]))
		ua_glazing += a * float(g["u"])
		a_glazed += a
		tau_lw_a += a * float(g["tau_lw"])
		ach_w += a * float(ACH_BASE.get(str(g["look"]), 1.0))
		var n: Vector3 = rot * (fd["normal"] as Vector3)
		var tilt := rad_to_deg(acos(clampf(n.y, -1.0, 1.0)))
		var az := fposmod(rad_to_deg(atan2(n.x, -n.z)), 360.0)
		if tilt < 5.0:
			az = 180.0
		var key := "%d_%d_%s" % [int(roundf(tilt / 10.0)), int(roundf(az / 15.0)) % 24, str(fd["material"])]
		if not bins.has(key):
			bins[key] = {"tilt": 0.0, "az": az, "area": 0.0, "tau": float(g["tau"]), "tau_d": float(g["tau_diffuse"])}
		var b: Dictionary = bins[key]
		b["tilt"] = (float(b["tilt"]) * float(b["area"]) + tilt * a) / (float(b["area"]) + a)
		b["area"] = float(b["area"]) + a
	var floor_a := float(st["floor_area_m2"])
	var bed_a := minf(float(st["bed_area_m2"]), floor_a)
	var barrels: Dictionary = d["barrels"]
	var nb := int(barrels["count"])
	var bh := clampf(float(s["mass"]["litres_each"]) / 208.0 * 0.88, 0.4, 1.6)
	var bd := GreenhouseBeds.BARREL_D
	var a_barrel_surf := float(nb) * (PI * bd * bh + PI * bd * bd * 0.25)
	var a_barrel_sil := float(nb) * bd * bh * 0.5 + float(nb) * PI * bd * bd * 0.25
	var sink := float(s["ground"]["sink_m"])
	var vents: Array = []
	for v in fr["vents"]:
		vents.append({"kind": str(v["kind"]), "area": float(v["area_m2"]), "h": float(v["height_m"])})
	var fan := GreenhouseMaterials.fan(str(s["fans"]["kind"]))
	var heater := GreenhouseMaterials.heater(str(s["heater"]))
	var light_w := float(st["light_w"])
	var lit_a := 0.0
	for b2 in d["beds"]:
		if (b2 as Dictionary).has("light"):
			lit_a += float(b2["area_m2"])
	var wave := EarthTemperature.annual_wave(opts.get("monthly_c", []) as Array)
	var cap_floor := maxf(floor_a - bed_a, 0.0) * FLOOR_DEPTH_M * SOIL_VOL_HEAT
	return {
		"bins": bins.values(), "ua_glazing": ua_glazing, "ua_opaque": ua_opaque, "a_glazed": a_glazed,
		"tau_lw": tau_lw_a / maxf(a_glazed, 1e-6), "ach": ach_w / maxf(a_glazed, 1e-6),
		"volume": maxf(float(st["volume_m3"]), 1.0), "floor_a": floor_a, "bed_a": bed_a,
		"path_a": maxf(floor_a - bed_a, 0.0), "a_back": a_back, "a_opaque": a_opaque, "a_earth": a_earth,
		"earth_depth": earth_depth_a / maxf(a_earth, 1e-6), "sink": sink,
		"c_water": float(barrels["litres"]) * CP_WATER, "a_barrel": a_barrel_surf, "a_barrel_sil": a_barrel_sil,
		"barrel_abs": float(ABSORB_BARREL.get(str(s["mass"]["colour"]), 0.92)),
		"c_soil": maxf(bed_a, 1.0) * SOIL_DEPTH_M * SOIL_VOL_HEAT,
		"c_struct": cap_floor + cap_walls + 1.0e5,
		"vents": vents, "fan_m3s": float(fan["m3s"]), "fan_w": float(fan["w"]), "fans": int(s["fans"]["count"]),
		"heater_w": float(heater["w"]), "heater_eff": float(heater["eff"]),
		"heater_fuel": str(heater["fuel"]), "light_w": light_w, "lit_a": lit_a,
		"ppfd_lights": float(s["lights"]["ppfd"]),
		"roof_plan": float(st["roof_plan_m2"]) if bool(s["rain"]["gutters"]) else 0.0,
		"shade": float(s["shade"]["cloth"]), "shade_months": (s["shade"]["months"] as Array).duplicate(),
		"control": (s["control"] as Dictionary).duplicate(), "lights": (s["lights"] as Dictionary).duplicate(),
		"wave": wave, "form": str(fr["form"]),
	}


static func initial_state(m: Dictionary, t_out: float, rh_out: float, doy: float = 180.0) -> Dictionary:
	var tg := ground_temp(m, doy, float(m["sink"]) + GROUND_PATH_M, t_out)
	var t0 := lerpf(t_out, tg, 0.4) + 3.0
	return {"t_air": t0, "w": humidity_ratio(t0, clampf(rh_out + 10.0, 30.0, 90.0)), "t_water": t0,
		"t_soil": t0, "t_struct": lerpf(t0, tg, 0.5), "fans_on": false, "heater_on": false,
		"day": -1, "dli": 0.0, "dli_sun": 0.0, "condensate_l": 0.0, "vent": 0.0,
		"ledger": {"sun": 0.0, "heater": 0.0, "lights": 0.0, "ground": 0.0, "skin": 0.0, "longwave": 0.0,
			"vent": 0.0, "latent": 0.0, "stored": 0.0}, "water_l": 0.0, "transp_l": 0.0}


# --- psychrometrics -----------------------------------------------------------

## Saturation vapour pressure, kPa (Tetens, FAO-56 eq. 11).
static func es_kpa(t_c: float) -> float:
	return 0.6108 * exp(17.27 * t_c / (t_c + 237.3))


static func humidity_ratio(t_c: float, rh_pct: float, p_kpa: float = P_ATM_KPA) -> float:
	var pv := es_kpa(t_c) * clampf(rh_pct, 0.0, 100.0) / 100.0
	return 0.622 * pv / maxf(p_kpa - pv, 1.0)


static func rh_of(t_c: float, w: float, p_kpa: float = P_ATM_KPA) -> float:
	var pv := w * p_kpa / (0.622 + w)
	return clampf(100.0 * pv / es_kpa(t_c), 0.0, 100.0)


static func w_sat(t_c: float, p_kpa: float = P_ATM_KPA) -> float:
	return humidity_ratio(t_c, 100.0, p_kpa)


## Slope of the saturation curve, kPa/°C (FAO-56 eq. 13).
static func delta_kpa(t_c: float) -> float:
	return 4098.0 * es_kpa(t_c) / pow(t_c + 237.3, 2.0)


## Clear-sky emissivity, Berdahl & Martin (1984), dew point in °C, raised
## toward 1 by cloud.
static func sky_temp_c(t_out: float, rh_out: float, cloud: float) -> float:
	var td := dew_point_c(t_out, rh_out)
	var eps := clampf(0.711 + 0.56 * (td / 100.0) + 0.73 * pow(td / 100.0, 2.0), 0.5, 1.0)
	eps = eps + (1.0 - eps) * 0.8 * clampf(cloud, 0.0, 1.0)
	return pow(eps, 0.25) * (t_out + 273.15) - 273.15


static func dew_point_c(t_c: float, rh_pct: float) -> float:
	var a := 17.27
	var b := 237.3
	var g := log(maxf(rh_pct, 1.0) / 100.0) + a * t_c / (b + t_c)
	return b * g / (a - g)


static func ground_temp(m: Dictionary, doy: float, depth: float, fallback: float) -> float:
	var g := EarthTemperature.ground_c(m["wave"], depth, doy)
	return g if is_finite(g) else fallback


# --- the step -------------------------------------------------------------------

## One step of `dt_h` hours (sub-stepped). inp: {t_out, rh_out, wind, ghi,
## cloud, sun_az, sun_el, rain_mmh, doy, hour, abs_h, has_real (GHI is
## measured), power_ok (AC up: fans, electric heater, lights), lai (canopy
## LAI, default 2.5), override: {vent, fans, heater, lights} (−1 / absent =
## the controller decides)}. Returns the last substep's readings.
static func step(m: Dictionary, st: Dictionary, inp: Dictionary, dt_h: float) -> Dictionary:
	var n := maxi(int(ceil(dt_h / MAX_SUB_H - 1e-9)), 1)
	var h := dt_h / float(n)
	var out := {}
	for i in n:
		out = _sub(m, st, inp, h)
	return out


static func _sub(m: Dictionary, st: Dictionary, inp: Dictionary, dt_h: float) -> Dictionary:
	var dt := dt_h * 3600.0
	var t_out := float(inp.get("t_out", 15.0))
	var rh_out := float(inp.get("rh_out", 60.0))
	var wind := maxf(float(inp.get("wind", 2.0)), 0.0)
	var cloud := clampf(float(inp.get("cloud", 0.3)), 0.0, 1.0)
	var doy := float(inp.get("doy", 180.0))
	var hour := float(inp.get("hour", 12.0))
	var w_out := humidity_ratio(t_out, rh_out)
	var lai := float(inp.get("lai", 2.5))
	var power_ok := bool(inp.get("power_ok", true))
	# Day bookkeeping (the daily light integral resets at midnight).
	var day := int(floor(float(inp.get("abs_h", doy * 24.0 + hour)) / 24.0))
	if day != int(st["day"]):
		st["day"] = day
		st["dli"] = 0.0
		st["dli_sun"] = 0.0
	# --- sun in ---------------------------------------------------------------
	var sun := 0.0
	var sun_el := float(inp.get("sun_el", -10.0))
	var ghi := maxf(float(inp.get("ghi", 0.0)), 0.0)
	if sun_el > -1.0 and ghi > 0.0:
		for b in m["bins"]:
			var bd: Dictionary = b
			var p := PvLabShading.poa(float(inp.get("sun_az", 180.0)), sun_el, float(bd["tilt"]), float(bd["az"]),
				ghi, bool(inp.get("has_real", true)), cloud)
			# A face's own sky view halves for what lies under the roof's other faces.
			sun += float(bd["area"]) * (float(p["beam"]) * float(bd["tau"])
				+ (float(p["sky"]) + float(p["ground"])) * float(bd["tau_d"]) * 0.5)
		# Light enters through the house's outline: never more than the sun on
		# its floor plan plus its walls' share.
		sun = minf(sun, ghi * (float(m["floor_a"]) + float(m["a_glazed"]) * 0.35))
	var month := clampi(int(doy / 30.44) + 1, 1, 12)
	if float(m["shade"]) > 0.0 and (m["shade_months"] as Array).has(month):
		sun *= 1.0 - float(m["shade"])
	sun *= 1.0 - REFLECT_OUT
	# Where it lands: barrels (their silhouette), the back wall, the canopy, the paths.
	var fa := maxf(float(m["floor_a"]), 1.0)
	var f_barrel := clampf(float(m["a_barrel_sil"]) / fa, 0.0, 0.5)
	var f_back := clampf(float(m["a_back"]) * 0.35 / fa, 0.0, 0.4)
	var rest := 1.0 - f_barrel - f_back
	var f_canopy := rest * float(m["bed_a"]) / fa
	var f_path := rest - f_canopy
	var q_barrel_sun := sun * f_barrel * float(m["barrel_abs"])
	var q_back_sun := sun * f_back * ABSORB_WALL
	var q_canopy_sun := sun * f_canopy * ABSORB_CANOPY
	var q_path_sun := sun * f_path * ABSORB_FLOOR
	var q_sun_lost := sun * (f_barrel * (1.0 - float(m["barrel_abs"])) + f_back * (1.0 - ABSORB_WALL)
		+ f_canopy * (1.0 - ABSORB_CANOPY) + f_path * (1.0 - ABSORB_FLOOR))
	var ppfd_sun := (sun / (1.0 - REFLECT_OUT)) / fa * PAR_FRACTION * UMOL_PER_J_PAR
	# --- control -------------------------------------------------------------
	var ctl := GreenhouseControl.decide(m, st, {"hour": hour, "t_out": t_out, "wind": wind,
		"rain_mmh": float(inp.get("rain_mmh", 0.0)), "ppfd_sun": ppfd_sun}, inp.get("override", {}) as Dictionary)
	var vent := float(ctl["vent"])
	var fans_on := bool(ctl["fans"]) and power_ok
	var heater_on := bool(ctl["heater"]) and (power_ok or str(m["heater_fuel"]) == "propane")
	var lights_on := bool(ctl["lights"]) and power_ok and float(m["light_w"]) > 0.0
	st["fans_on"] = bool(ctl["fans"])
	st["heater_on"] = bool(ctl["heater"])
	st["vent"] = vent
	var q_heater := float(m["heater_w"]) * float(m["heater_eff"]) if heater_on else 0.0
	var q_lights := float(m["light_w"]) if lights_on else 0.0
	var ppfd_lights := float(m["ppfd_lights"]) * float(m["lit_a"]) / fa if lights_on else 0.0
	var vapour_heater := 0.0
	if heater_on and str(m["heater_fuel"]) == "propane" and float(m["heater_eff"]) >= 0.99:
		vapour_heater = float(m["heater_w"]) / (GreenhouseMaterials.PROPANE_LHV_MJ_KG * 1e6) * GreenhouseMaterials.PROPANE_H2O_PER_KG
	# --- conductances --------------------------------------------------------
	var wind_f := 1.0 + 0.04 * maxf(wind - 2.0, 0.0)
	var ua_skin := float(m["ua_glazing"]) * minf(wind_f, 1.6) + float(m["ua_opaque"])
	var g_soil := H_SOIL * float(m["bed_a"])
	var g_floor := H_FLOOR * float(m["path_a"]) + H_WALL * (float(m["a_opaque"]) + float(m["a_earth"]))
	var g_barrel := H_BARREL * float(m["a_barrel"])
	var tg_floor := ground_temp(m, doy, float(m["sink"]) + GROUND_PATH_M, t_out)
	var tg_walls := ground_temp(m, doy, float(m["earth_depth"]) + GROUND_PATH_M, t_out)
	var g_ground_floor := K_SOIL / GROUND_PATH_M * float(m["floor_a"])
	var g_ground_walls := K_SOIL / GROUND_PATH_M * float(m["a_earth"])
	var t_sky := sky_temp_c(t_out, rh_out, cloud)
	var a_lw := float(m["floor_a"]) * float(m["tau_lw"])
	# --- air: quasi-steady, iterated --------------------------------------------
	# A thermostat cycles within minutes: over a step the heater and the fans
	# run at the duty that holds their setpoint (all on when that is short of
	# it), so the air never swings from setpoint to outside and back.
	var ctl_c: Dictionary = m["control"]
	var heat_target := (float(ctl_c["heat_on_c"]) + float(ctl_c["heat_off_c"])) * 0.5
	var fan_target := (float(ctl_c["fan_on_c"]) + float(ctl_c["fan_off_c"])) * 0.5
	var ta := float(st["t_air"])
	var w := float(st["w"])
	var q_vent := 0.0
	var e_transp := 0.0
	var e_soil := 0.0
	var e_cond := 0.0
	var q_canopy_sens := 0.0
	var ovr: Dictionary = inp.get("override", {}) as Dictionary
	var heat_forced := ovr.has("heater") and int(ovr["heater"]) >= 0
	var fans_forced := ovr.has("fans") and int(ovr["fans"]) >= 0
	var heat_duty := 1.0 if heater_on else 0.0
	var fan_duty := 1.0 if fans_on else 0.0
	var q_heater_full := q_heater
	var q_fans_full := float(m["fans"]) * float(m["fan_m3s"]) if fans_on else 0.0
	var mdot := 0.0
	var air := {}
	for _it in 5:
		var q_nat := _vent_flow(m, vent, ta, t_out, wind) + float(m["ach"]) * float(m["volume"]) / 3600.0 * (1.0 + 0.1 * wind)
		# Transpiration (Penman–Monteith on the canopy) and evaporation from
		# the wet bed soil (a wet surface, Penman with r_a + r_soil), kg/s.
		var rn_c := (q_canopy_sun + q_lights * 0.5) / maxf(float(m["bed_a"]), 1.0)
		e_transp = _transpiration(ta, w, rn_c, lai) * float(m["bed_a"])
		e_soil = _soil_evaporation(float(st["t_soil"]), w, lai) * float(m["bed_a"])
		air = _solve_air(m, st, ta, t_out, w_out, q_nat + q_fans_full * fan_duty, ua_skin, g_soil, g_floor, g_barrel,
			q_canopy_sun, q_lights, q_heater_full * heat_duty, e_transp + e_soil, e_transp, vapour_heater * heat_duty)
		if heater_on and q_heater_full > 0.0 and not heat_forced:
			var t_off := float(_solve_air(m, st, ta, t_out, w_out, q_nat + q_fans_full * fan_duty, ua_skin, g_soil, g_floor,
				g_barrel, q_canopy_sun, q_lights, 0.0, e_transp + e_soil, e_transp, 0.0)["t"])
			var t_on := float(_solve_air(m, st, ta, t_out, w_out, q_nat + q_fans_full * fan_duty, ua_skin, g_soil, g_floor,
				g_barrel, q_canopy_sun, q_lights, q_heater_full, e_transp + e_soil, e_transp, vapour_heater)["t"])
			heat_duty = clampf((heat_target - t_off) / maxf(t_on - t_off, 1e-6), 0.0, 1.0)
		if fans_on and q_fans_full > 0.0 and not fans_forced:
			var f0 := float(_solve_air(m, st, ta, t_out, w_out, q_nat, ua_skin, g_soil, g_floor, g_barrel,
				q_canopy_sun, q_lights, q_heater_full * heat_duty, e_transp + e_soil, e_transp, vapour_heater * heat_duty)["t"])
			var f1 := float(_solve_air(m, st, ta, t_out, w_out, q_nat + q_fans_full, ua_skin, g_soil, g_floor, g_barrel,
				q_canopy_sun, q_lights, q_heater_full * heat_duty, e_transp + e_soil, e_transp, vapour_heater * heat_duty)["t"])
			fan_duty = clampf((f0 - fan_target) / maxf(f0 - f1, 1e-6), 0.0, 1.0) if f0 > f1 else 1.0
		q_vent = q_nat + q_fans_full * fan_duty
		air = _solve_air(m, st, ta, t_out, w_out, q_vent, ua_skin, g_soil, g_floor, g_barrel,
			q_canopy_sun, q_lights, q_heater_full * heat_duty, e_transp + e_soil, e_transp, vapour_heater * heat_duty)
		ta = float(air["t"])
		w = float(air["w"])
	e_cond = float(air["cond"])
	mdot = RHO_AIR * q_vent
	q_heater = q_heater_full * heat_duty
	vapour_heater *= heat_duty
	q_canopy_sens = q_canopy_sun + q_lights - LAMBDA * e_transp
	# --- masses: explicit step -------------------------------------------------
	var t_soil := float(st["t_soil"])
	var t_struct := float(st["t_struct"])
	var t_water := float(st["t_water"])
	var bed_share := float(m["bed_a"]) / fa
	var lw_soil := a_lw * bed_share * 0.95 * SIGMA * (pow(t_soil + 273.15, 4.0) - pow(t_sky + 273.15, 4.0))
	var lw_floor := a_lw * (1.0 - bed_share) * 0.95 * SIGMA * (pow(t_struct + 273.15, 4.0) - pow(t_sky + 273.15, 4.0))
	var q_soil_ground := 1.5 * float(m["bed_a"]) * (tg_floor - t_soil)
	var q_floor_ground := g_ground_floor * (1.0 - bed_share) * (tg_floor - t_struct) + g_ground_walls * (tg_walls - t_struct)
	var d_soil := -g_soil * (t_soil - ta) - lw_soil + q_soil_ground - LAMBDA * e_soil
	var d_struct := q_path_sun + q_back_sun - g_floor * (t_struct - ta) - lw_floor + q_floor_ground
	var d_water := q_barrel_sun - g_barrel * (t_water - ta)
	st["t_soil"] = t_soil + d_soil * dt / float(m["c_soil"])
	st["t_struct"] = t_struct + d_struct * dt / float(m["c_struct"])
	if float(m["c_water"]) > 0.0:
		st["t_water"] = t_water + d_water * dt / float(m["c_water"])
	else:
		st["t_water"] = ta
	st["t_air"] = ta
	st["w"] = w
	var cond_l := e_cond * dt
	st["condensate_l"] = float(st["condensate_l"]) + cond_l
	st["transp_l"] = float(st["transp_l"]) + e_transp * dt
	st["water_l"] = float(st["water_l"]) + (e_transp + e_soil) * dt
	st["dli"] = float(st["dli"]) + (ppfd_sun + ppfd_lights) * dt / 1e6
	st["dli_sun"] = float(st["dli_sun"]) + ppfd_sun * dt / 1e6
	# --- the ledger (J) ----------------------------------------------------------
	var lg: Dictionary = st["ledger"]
	var mdot2 := RHO_AIR * q_vent
	lg["sun"] = float(lg["sun"]) + (q_barrel_sun + q_back_sun + q_canopy_sun + q_path_sun) * dt
	lg["heater"] = float(lg["heater"]) + q_heater * dt
	lg["lights"] = float(lg["lights"]) + q_lights * dt
	lg["ground"] = float(lg["ground"]) + (q_soil_ground + q_floor_ground) * dt
	lg["skin"] = float(lg["skin"]) + ua_skin * (ta - t_out) * dt
	lg["longwave"] = float(lg["longwave"]) + (lw_soil + lw_floor) * dt
	lg["vent"] = float(lg["vent"]) + mdot2 * CP_AIR * (ta - t_out) * dt
	lg["latent"] = float(lg["latent"]) + LAMBDA * (e_transp + e_soil - e_cond) * dt
	lg["stored"] = float(lg["stored"]) + (d_soil + d_struct + (d_water if float(m["c_water"]) > 0.0 else 0.0)) * dt
	var rain_lph := float(m["roof_plan"]) * 0.9 * maxf(float(inp.get("rain_mmh", 0.0)), 0.0)
	var rh := rh_of(ta, w)
	return {"t_air": ta, "rh": rh, "w": w, "vpd": CropPhysiology.vpd_kpa(ta, rh), "t_soil": float(st["t_soil"]),
		"t_water": float(st["t_water"]), "t_struct": float(st["t_struct"]), "t_out": t_out, "rh_out": rh_out,
		"sun_w": sun, "sun_lost_w": q_sun_lost, "ppfd_sun": ppfd_sun, "ppfd_lights": ppfd_lights,
		"ppfd": ppfd_sun + ppfd_lights, "par_wm2": (ppfd_sun + ppfd_lights) / UMOL_PER_J_PAR,
		"dli": float(st["dli"]), "vent": vent, "fans": fans_on, "heater": heater_on, "lights": lights_on,
		"air_m3s": q_vent, "transp_lph": e_transp * 3600.0, "soil_evap_lph": e_soil * 3600.0,
		"fan_duty": fan_duty, "heater_duty": heat_duty, "cond_lph": cond_l / dt_h,
		"rain_lph": rain_lph, "q_heater_w": q_heater, "q_lights_w": q_lights,
		"power_w": (float(m["fans"]) * float(m["fan_w"]) * fan_duty if fans_on else 0.0)
			+ (float(m["heater_w"]) * heat_duty if heater_on and str(m["heater_fuel"]) == "electric" else 0.0)
			+ q_lights + (GreenhouseMaterials.VENT_MOTOR_W if vent > 0.0 and vent < 1.0 else 0.0),
		"propane_kg_h": float(m["heater_w"]) * heat_duty / (GreenhouseMaterials.PROPANE_LHV_MJ_KG * 1e6) * 3600.0
			if heater_on and str(m["heater_fuel"]) == "propane" else 0.0,
		"t_sky": t_sky, "t_ground": tg_floor}


## The air for given flows and heat: humidity from the vapour balance
## (condensation on the cover linear above its dew point, never past
## saturation), then the temperature from the heat balance. {t, w, cond}.
static func _solve_air(m: Dictionary, st: Dictionary, ta: float, t_out: float, w_out: float, q_air: float,
		ua_skin: float, g_soil: float, g_floor: float, g_barrel: float, q_canopy_sun: float, q_lights: float,
		q_heater: float, e_crop: float, e_transp: float, vapour_heater: float) -> Dictionary:
	var mdot := RHO_AIR * q_air
	var t_glass := ta - float(m["ua_glazing"]) / maxf(float(m["a_glazed"]), 1.0) / H_IN_GLAZING * (ta - t_out)
	var ws_g := w_sat(t_glass)
	var k_c := H_IN_GLAZING / CP_AIR * float(m["a_glazed"])
	var vin := mdot * w_out + e_crop + vapour_heater
	var w := vin / maxf(mdot, 1e-6)
	if w > ws_g:
		w = (vin + k_c * ws_g) / maxf(mdot + k_c, 1e-6)
	w = minf(w, w_sat(ta))
	var cond := maxf(vin - mdot * w, 0.0)
	# Σ G (T_k − T_a) + direct heat = 0. The canopy's sun and the lights go to
	# the air less the transpiration's latent heat; condensation gives its
	# latent heat back to the air at the cover.
	var g_air := ua_skin + mdot * CP_AIR + g_soil + g_floor + g_barrel
	var num := (ua_skin + mdot * CP_AIR) * t_out + g_soil * float(st["t_soil"]) + g_floor * float(st["t_struct"]) 		+ g_barrel * float(st["t_water"]) + q_canopy_sun + q_lights - LAMBDA * e_transp + q_heater + LAMBDA * cond
	return {"t": num / maxf(g_air, 1e-6), "w": w, "cond": cond}


## Evaporation from the wet bed soil, kg/s per m²: a wet surface at the
## soil's temperature into the air (Penman's form with r_a 200 s/m and a
## surface resistance of 300 s/m, falling to a third under a full canopy).
static func _soil_evaporation(t_soil: float, w: float, lai: float) -> float:
	var e_a := w * P_ATM_KPA / (0.622 + w)
	var de := maxf(es_kpa(t_soil) - e_a, 0.0) * 1000.0
	var gamma := 66.5
	var r := (200.0 + 300.0) * (1.0 + clampf(lai, 0.0, 4.0) * 0.5)
	return RHO_AIR * CP_AIR * de / (gamma * r) / LAMBDA


## Vent air flow, m³/s, at opening `frac` (0..1).
static func _vent_flow(m: Dictionary, frac: float, ta: float, t_out: float, wind: float) -> float:
	if frac <= 0.0:
		return 0.0
	var low := 0.0
	var high := 0.0
	var a_low := 0.0
	var a_high := 0.0
	var a_all := 0.0
	for v in m["vents"]:
		var vd: Dictionary = v
		var a := float(vd["area"]) * frac
		a_all += a
		if str(vd["kind"]) == "sides":
			a_low += a
			low = float(vd["h"])
		else:
			a_high += a
			high = maxf(high, float(vd["h"]))
	if a_all <= 0.0:
		return 0.0
	var dT := absf(ta - t_out)
	var tm := (ta + t_out) * 0.5 + 273.15
	var q_stack := 0.0
	if a_low > 0.0 and a_high > 0.0:
		var a_eff := 1.0 / sqrt(1.0 / (a_low * a_low) + 1.0 / (a_high * a_high))
		q_stack = CD * a_eff * sqrt(2.0 * G * maxf(high - low, 0.3) * dT / tm)
	else:
		# One opening, air in and out of it: a third of the area, half its height.
		q_stack = CD * a_all / 3.0 * sqrt(G * 0.5 * dT / tm)
	var q_wind := CW * a_all * wind
	return sqrt(q_stack * q_stack + q_wind * q_wind)


## Canopy transpiration, kg/s per m² of bed: Penman–Monteith with LAI
## (big-leaf), r_b ≈ 200 s/m, stomata opening with light (Stanghellini 1987).
static func _transpiration(ta: float, w: float, rn_wm2: float, lai: float) -> float:
	if lai <= 0.0:
		return 0.0
	var vpd := maxf(es_kpa(ta) - w * P_ATM_KPA / (0.622 + w), 0.0) * 1000.0
	var delta := delta_kpa(ta) * 1000.0
	var gamma := 66.5
	var rb := 200.0
	var rs := 100.0 * (1.0 + 10.0 / (maxf(rn_wm2, 0.0) / 25.0 + 1.0))
	var rn := maxf(rn_wm2, 0.0)
	var le := (delta * rn + 2.0 * lai * RHO_AIR * CP_AIR * vpd / rb) / (delta + gamma * (1.0 + rs / rb))
	return maxf(le, 0.0) / LAMBDA
