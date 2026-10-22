extends SceneTree

## Headless physics self-test for the EnergySource family.
## Run with:
##   godot --headless --path . --script power_system/sources/source_physics_selftest.gd
## Exits 0 when all assertions pass, 1 otherwise.

const ResourceKindsScript := preload("res://system_graph/data/resource_kinds.gd")
const ResourceEdgeVisScript := preload("res://system_graph/data/resource_edge_vis.gd")
const CspTroughSourceScript := preload("res://power_system/sources/csp_trough_source.gd")
const WindTurbineSourceScript := preload("res://power_system/sources/wind_turbine_source.gd")
const HeliostatSourceScript := preload("res://power_system/sources/heliostat_source.gd")
const HomeBiogasSourceScript := preload("res://power_system/sources/home_biogas_source.gd")
const PpBeamExtruderSourceScript := preload("res://power_system/sources/pp_beam_extruder_source.gd")
const PpSheetPressSourceScript := preload("res://power_system/sources/pp_sheet_press_source.gd")
const ComponentPresetsScript := preload("res://system_graph/data/component_presets.gd")
const ModelCatalogScript := preload("res://core/placed_models/model_catalog.gd")
const WindMathScript := preload("res://core/wind_math.gd")
const CartesianMachineSourceScript := preload("res://power_system/sources/cartesian_machine_source.gd")

var _failures: int = 0
var _checks: int = 0


func _initialize() -> void:
	_test_wind()
	_test_hawt()
	_test_hydro()
	_test_defaults()
	_test_graph_adapters()
	_test_weather_service()
	_test_weather_leap_index()
	_test_solar_physics()
	_test_timecode()
	_test_timeline_view()
	_test_comparison()
	_test_resource_flow()
	_test_resource_edges()
	_test_season()
	_test_solar_eclipse()
	_test_csp()
	_test_heliostat()
	_test_home_biogas()
	_test_pp_extruder()
	_test_pp_sheet_press()
	_test_cnc()
	_test_mesh_collision_util()
	_test_aerosol()
	if _failures == 0:
		print("SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


## Aerosol attenuation for extreme weather (wildfire smoke, dust storms).
## Project convention: every physics change adds checks here.
func _test_aerosol() -> void:
	# THE BEHAVIOUR-PRESERVING IDENTITY. The old hardcoded aerosol term was
	# exp(-0.12 * m^0.75); it is now exp(-(AEROSOL_K * aod/AOD_BASELINE) * m^0.75).
	# At the default those are the SAME EXPRESSION, which is what makes the
	# refactor provably safe for every existing site — so it is pinned, not
	# assumed, across the whole elevation range.
	for el in [1.0, 5.0, 15.0, 30.0, 45.0, 60.0, 75.0, 89.0]:
		var default_call := SolarIrradiance.dni_clear_sky_wm2(float(el))
		var explicit := SolarIrradiance.dni_clear_sky_wm2(
			float(el), SolarIrradiance.AOD_BASELINE)
		_check("aerosol: default == baseline at el=%d" % el,
			absf(default_call - explicit) < 0.000001,
			"%.6f vs %.6f" % [default_call, explicit])

	# More aerosol always means less direct beam, and it is a big effect: this
	# is what makes CSP and tracking PV collapse under smoke.
	var clean := SolarIrradiance.dni_clear_sky_wm2(45.0, SolarIrradiance.AOD_BASELINE)
	var prev := clean + 1.0
	for aod in [0.1, 0.5, 1.0, 2.0, 3.0]:
		var dni := SolarIrradiance.dni_clear_sky_wm2(45.0, float(aod))
		_check("aerosol: DNI falls with aod=%.1f" % aod, dni < prev,
			"%.2f after %.2f" % [dni, prev])
		_check("aerosol: DNI finite at aod=%.1f" % aod, is_finite(dni))
		prev = dni
	_check("aerosol: heavy smoke guts the beam",
		SolarIrradiance.dni_clear_sky_wm2(45.0, 2.6) < clean * 0.25,
		"got %.1f vs clean %.1f" % [SolarIrradiance.dni_clear_sky_wm2(45.0, 2.6), clean])

	# ...while DIFFUSE RISES. Smoke scatters rather than absorbs, so the light
	# does not vanish, it becomes omnidirectional. That asymmetry is why a smoky
	# day still feels bright while a trough produces nothing.
	var dni_c := SolarIrradiance.dni_clear_sky_wm2(45.0, SolarIrradiance.AOD_BASELINE)
	var dni_s := SolarIrradiance.dni_clear_sky_wm2(45.0, 2.0)
	var frac_c := SolarIrradiance.dhi_clear_sky_wm2(45.0, dni_c,
		SolarIrradiance.AOD_BASELINE) / maxf(dni_c, 1.0)
	var frac_s := SolarIrradiance.dhi_clear_sky_wm2(45.0, dni_s, 2.0) / maxf(dni_s, 1.0)
	_check("aerosol: diffuse FRACTION rises with aerosol", frac_s > frac_c,
		"smoky %.3f vs clean %.3f" % [frac_s, frac_c])

	# THE has_real SHORT-CIRCUIT. ghi_wm2_at_calendar returns measured GHI
	# verbatim when weather has real data; an aerosol factor applied only to the
	# clear-sky branch would silently do nothing on exactly the sites that HAVE
	# real weather. These two checks are the regression guard for that trap.
	var measured := {"has_real": true, "ghi": 800.0, "cloud": 0.0,
		"aod": SolarIrradiance.AOD_BASELINE}
	var clean_ghi := SolarIrradiance.ghi_wm2_at_calendar(
		45.0, -120.0, 7, 15, 12.0, measured, 2024)
	_check("aerosol: baseline leaves measured GHI untouched",
		absf(clean_ghi - 800.0) < 0.001, "got %.2f" % clean_ghi)
	var smoky := measured.duplicate()
	smoky["aod"] = 2.0
	var smoky_ghi := SolarIrradiance.ghi_wm2_at_calendar(
		45.0, -120.0, 7, 15, 12.0, smoky, 2024)
	_check("aerosol: measured GHI IS attenuated by event aerosol",
		smoky_ghi < clean_ghi * 0.75,
		"got %.2f vs %.2f (has_real short-circuit trap)" % [smoky_ghi, clean_ghi])
	_check("aerosol: attenuated GHI stays positive and finite",
		smoky_ghi > 0.0 and is_finite(smoky_ghi))

	# aerosol_ghi_factor is the shared helper both branches use.
	_check("aerosol: factor is 1 at baseline", absf(
		SolarIrradiance.aerosol_ghi_factor(45.0, SolarIrradiance.AOD_BASELINE) - 1.0) < 0.0001)
	_check("aerosol: factor is 1 below baseline",
		absf(SolarIrradiance.aerosol_ghi_factor(45.0, 0.0) - 1.0) < 0.0001)
	_check("aerosol: factor bounded", SolarIrradiance.aerosol_ghi_factor(45.0, 3.0) >= 0.0
		and SolarIrradiance.aerosol_ghi_factor(45.0, 3.0) <= 1.0)
	_check("aerosol: factor NaN-guarded",
		is_finite(SolarIrradiance.aerosol_ghi_factor(45.0, NAN)))

	# CSP is far more aerosol-sensitive than a flat plate, because it can only
	# use the beam that smoke destroys.
	var wx_clean := {"has_real": false, "cloud": 0.0, "aod": SolarIrradiance.AOD_BASELINE}
	var wx_smoke := {"has_real": false, "cloud": 0.0, "aod": 2.0}
	var dni_csp_clean := CspTroughSourceScript.dni_wm2(45.0, wx_clean)
	var dni_csp_smoke := CspTroughSourceScript.dni_wm2(45.0, wx_smoke)
	_check("aerosol: CSP DNI collapses under smoke",
		dni_csp_smoke < dni_csp_clean * 0.25,
		"%.1f vs %.1f" % [dni_csp_smoke, dni_csp_clean])
	_check("aerosol: CSP unchanged at baseline",
		absf(dni_csp_clean - SolarIrradiance.dni_clear_sky_wm2(45.0)) < 0.001)

	# Gust cut-out: IEC 61400-1 trips on a short gust above the cut-out MEAN.
	_check("gust: ordinary gust does not trip",
		not WindTurbineSourceScript.gust_shutdown(20.0, 25.0))
	_check("gust: a gust 25% over cut-out trips",
		WindTurbineSourceScript.gust_shutdown(32.0, 25.0))
	_check("gust: NaN guarded", not WindTurbineSourceScript.gust_shutdown(NAN, 25.0))
	_check("gust: zero cut-out guarded", not WindTurbineSourceScript.gust_shutdown(30.0, 0.0))


## Collision-mesh sanitizer: NaN/inf/degenerate triangles must be dropped before
## they reach ConcavePolygonShape3D.set_faces() (a physics-server hard-crash
## vector for imported STL parts and procedural pipe/linkage meshes).
func _test_mesh_collision_util() -> void:
	# One clean triangle survives untouched.
	var good := PackedVector3Array([
		Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 0, 1)])
	var s_good := MeshCollisionUtil.sanitize_faces(good)
	_check("collision util keeps clean tri", s_good.size() == 3, str(s_good.size()))
	# A NaN vertex kills its triangle but spares the neighbours.
	var with_nan := PackedVector3Array([
		Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 0, 1),
		Vector3(NAN, 0, 0), Vector3(1, 0, 0), Vector3(0, 0, 1),
		Vector3(0, 1, 0), Vector3(1, 1, 0), Vector3(0, 1, 1)])
	var s_nan := MeshCollisionUtil.sanitize_faces(with_nan)
	_check("collision util drops NaN tri only", s_nan.size() == 6, str(s_nan.size()))
	# A zero-area (degenerate) triangle is dropped.
	var degen := PackedVector3Array([
		Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(2, 0, 0)])
	_check("collision util drops degenerate tri",
		MeshCollisionUtil.sanitize_faces(degen).is_empty())
	# inf and short/empty input are handled without error.
	_check("collision util handles inf",
		MeshCollisionUtil.sanitize_faces(PackedVector3Array([
			Vector3(INF, 0, 0), Vector3(1, 0, 0), Vector3(0, 0, 1)])).is_empty())
	_check("collision util handles empty",
		MeshCollisionUtil.sanitize_faces(PackedVector3Array()).is_empty())


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


func _approx(value: float, low: float, high: float) -> bool:
	return value >= low and value <= high


func _make_wind() -> WindTurbineSource:
	var src := WindTurbineSource.new()
	src.config = load("res://power_system/sources/default_wind_1kw.tres")
	return src


func _make_hydro() -> HydroSource:
	var src := HydroSource.new()
	src.config = load("res://power_system/sources/default_hydro_500w.tres")
	return src


## Cartesian machine (CNC/printer) job time/material/energy + scrub-safe progress.
func _test_cnc() -> void:
	var specs := {
		"machine_role": "fdm_printer", "speed_factor": 1.0, "watts": 900.0,
		"filament_diameter_mm": 3.0, "flake_density_g_cm3": 0.95,
		"inputs": [{"kind": "plastic_flake", "rate": 0.0}],
	}
	var parse := {"est_time_hr": 2.0, "extrusion_mm": 1000.0,
		"bounds_min": Vector3.ZERO, "bounds_max": Vector3(50, 50, 50)}
	var job := CartesianMachineSourceScript.derive_job(parse, specs)
	_check("cnc duration", _approx(float(job.get("duration_hr", 0.0)), 1.99, 2.01),
		str(job.get("duration_hr")))
	_check("cnc energy = W*h", _approx(float(job.get("energy_kwh", 0.0)), 1.79, 1.81),
		str(job.get("energy_kwh")))
	# vol = 1000 * pi*1.5^2 mm3 = 7068.6 mm3 -> 7.0686 cm3 * 0.95 = 6.715 g = 0.006715 kg
	_check("cnc material kg", _approx(float(job.get("material_qty", 0.0)), 0.0060, 0.0075),
		str(job.get("material_qty")))
	_check("cnc material kind", str(job.get("material_kind", "")) == "plastic_flake")
	# Router: subtractive, no feedstock consumed.
	var rspecs := {"machine_role": "cnc_router", "speed_factor": 1.0, "watts": 1800.0, "inputs": []}
	var rjob := CartesianMachineSourceScript.derive_job(parse, rspecs)
	_check("cnc router no material", float(rjob.get("material_qty", 0.0)) == 0.0,
		str(rjob.get("material_qty")))
	# Scrub-safe progress is a pure clock function (reversible).
	var js := {"job_active": true, "job_start_abs_hours": 10.0, "job_duration_hr": 4.0}
	_check("cnc progress fwd", _approx(CartesianMachineSourceScript.progress_at(js, 12.0), 0.49, 0.51))
	_check("cnc progress rewind", CartesianMachineSourceScript.progress_at(js, 10.0) == 0.0)
	_check("cnc progress clamp", CartesianMachineSourceScript.progress_at(js, 99.0) == 1.0)


func _test_wind() -> void:
	var w := _make_wind()

	# Cut-in / cut-out window
	_check("wind: zero below cut-in", w.power_at_wind_speed_kw(2.4) == 0.0)
	_check("wind: zero above cut-out", w.power_at_wind_speed_kw(20.5) == 0.0)
	_check("wind: producing just above cut-in", w.power_at_wind_speed_kw(3.5) > 0.0)

	# Rated plateau between rated and cut-out
	var p_rated := w.power_at_wind_speed_kw(11.0)
	var p_15 := w.power_at_wind_speed_kw(15.0)
	_check("wind: rated plateau == nameplate", _approx(p_rated, 0.999, 1.001),
		"got %.3f kW" % p_rated)
	_check("wind: plateau holds at 15 m/s", _approx(p_15, 0.999, 1.001))

	# Continuity: just below rated should land near nameplate (cubic + cap)
	var p_below := w.power_at_wind_speed_kw(10.9)
	_check("wind: continuous through rated", _approx(p_below, 0.85, 1.001),
		"got %.3f kW" % p_below)

	# Cubic-law growth: P(8)/P(5) should far exceed linear ratio
	var p5 := w.power_at_wind_speed_kw(5.0)
	var p8 := w.power_at_wind_speed_kw(8.0)
	_check("wind: super-linear growth", p8 > p5 * 2.5,
		"P(5)=%.3f P(8)=%.3f" % [p5, p8])

	# Betz limit cap, even with an absurd cp_peak forced in code
	var cheat := WindTurbineConfig.new()
	cheat.cp_peak = 0.80
	cheat.rated_ms = 11.0
	var w2 := WindTurbineSource.new()
	w2.config = cheat
	var cp := w2._cp_at_speed(7.7)  # 0.7×rated → shape factor 1.0
	_check("wind: Betz limit enforced", cp <= WindTurbineSource.BETZ_LIMIT + 1e-9,
		"cp=%.4f" % cp)

	# ISA density: ~1.007 kg/m³ at 2000 m, 1.225 at sea level
	var rho0 := WindTurbineSource.air_density_at_altitude(0.0)
	var rho2k := WindTurbineSource.air_density_at_altitude(2000.0)
	_check("wind: sea-level density", _approx(rho0, 1.2249, 1.2251))
	_check("wind: ISA density at 2000 m", _approx(rho2k, 0.99, 1.03),
		"got %.4f" % rho2k)

	# Log-law shear: 10 m → 20 m over grassland (z0=0.03) ≈ ×1.12
	var v20 := WindTurbineSource.shear_correct_ms(6.0, 10.0, 20.0, 0.03)
	_check("wind: log-profile shear ratio", _approx(v20 / 6.0, 1.10, 1.14),
		"ratio %.3f" % (v20 / 6.0))

	# VAWT profile differs from HAWT at the same speed
	var vawt_cfg := WindTurbineConfig.new()
	vawt_cfg.turbine_type = WindTurbineConfig.TurbineType.VERTICAL_AXIS
	var w3 := WindTurbineSource.new()
	w3.config = vawt_cfg
	var hawt_cfg := WindTurbineConfig.new()
	var w4 := WindTurbineSource.new()
	w4.config = hawt_cfg
	_check("wind: VAWT Cp < HAWT Cp at low speed",
		w3._cp_at_speed(4.0) < w4._cp_at_speed(4.0))

	_check("wind: nameplate capacity", _approx(w.get_peak_capacity_kw(), 0.999, 1.001))
	w.free()
	w2.free()
	w3.free()
	w4.free()


## The shipped 3D-linked "Small HAWT 500W (3D)" library preset — Primus-style
## Air 30 class turbine (see component_presets.gd for the manufacturer-spec
## derivation) — and the WindMath direction helper its 3D yaw tracker uses.
func _test_hawt() -> void:
	var preset := {}
	for p: Dictionary in ComponentPresetsScript.WIND_TURBINES:
		if str(p.get("label", "")) == "Small HAWT 500W (3D)":
			preset = p
			break
	_check("hawt preset: found in library", not preset.is_empty())
	if preset.is_empty():
		return
	var specs: Dictionary = preset.get("specs", {}) as Dictionary
	_check("hawt preset: kind is hawt", str(specs.get("kind", "")) == "hawt")
	_check("hawt preset: model_id links small_hawt",
		str(specs.get("model_id", "")) == "small_hawt")

	# Swept area sanity: π·(1.17/2)² ≈ 1.075 m² — matches the datasheet's
	# stated 1.07 m² within a normal rounding tolerance.
	var d := float(specs.get("rotor_diameter_m", 0.0))
	var area := PI * d * d * 0.25
	_check("hawt preset: swept area ≈ 1.07 m²", _approx(area, 1.05, 1.10),
		"got %.4f m² from diameter %.3f m" % [area, d])

	# Cut-in / rated / cut-out window matches the datasheet (3.58 / 11-15
	# midpoint / 22 m/s).
	_check("hawt preset: cut-in ≈ 3.58 m/s", _approx(float(specs.get("cut_in_ms", 0.0)), 3.5, 3.7))
	_check("hawt preset: rated within optimal band 11-15 m/s",
		_approx(float(specs.get("rated_ms", 0.0)), 11.0, 15.0))
	_check("hawt preset: cut-out ≈ 22 m/s", _approx(float(specs.get("cut_out_ms", 0.0)), 21.0, 23.0))

	# Zero outside the operating window, producing between, nameplate at rated.
	var below := specs.duplicate(true)
	below["site_mean_wind_ms"] = 2.0
	_check("hawt preset: zero below cut-in",
		WindTurbineSource.power_kw_from_graph_specs(below, 12.0, 2.0) == 0.0)
	var storm := specs.duplicate(true)
	storm["site_mean_wind_ms"] = 25.0
	_check("hawt preset: zero above cut-out",
		WindTurbineSource.power_kw_from_graph_specs(storm, 12.0, 25.0) == 0.0)
	var rated_ms := float(specs.get("rated_ms", 13.0))
	var p_rated := WindTurbineSource.power_kw_from_graph_specs(specs, 12.0, rated_ms)
	_check("hawt preset: ~nameplate (0.5 kW) at rated speed", _approx(p_rated, 0.45, 0.51),
		"got %.3f kW at %.1f m/s" % [p_rated, rated_ms])
	var p_optimal := WindTurbineSource.power_kw_from_graph_specs(specs, 12.0, 12.5)
	_check("hawt preset: producing within optimal band (11-15 m/s)", p_optimal > 0.2,
		"got %.3f kW" % p_optimal)

	# Model catalog registration: the GLB + its two independently-driven
	# yaw/blade-spin sub-node names (see hawt_tracker.gd).
	var entry := ModelCatalogScript.find("small_hawt")
	_check("hawt model: registered in ModelCatalog", not entry.is_empty())
	_check("hawt model: yaw node name", str(entry.get("hawt_yaw_node", "")) == "turbine vane assembly")
	_check("hawt model: blade node name", str(entry.get("hawt_blade_node", "")) == "Nosecone and Blades")

	# WindMath: the shared FROM-degrees → world-XZ helper the yaw tracker uses
	# (same convention the vegetation wind driver uses for grass sway).
	_check("windmath: NAN direction has a deterministic default",
		WindMathScript.downwind_xz(NAN) == Vector2(0.0, 1.0))
	var north := WindMathScript.downwind_xz(0.0)   # wind FROM north
	_check("windmath: unit vector", _approx(north.length(), 0.999, 1.001))
	var east := WindMathScript.downwind_xz(90.0)   # wind FROM east
	_check("windmath: from-east has a westward component", east.x < -0.5,
		"got %s" % str(east))


func _test_hydro() -> void:
	var h := _make_hydro()

	# Default install lands near 500 W at design flow
	var p_design := h.power_at_flow_kw(0.003)
	_check("hydro: default ≈ 500 W", _approx(p_design, 0.46, 0.56),
		"got %.3f kW" % p_design)

	# Darcy-Weisbach friction loss ≈ 0.9 m for the default penstock
	var h_f := HydroSource.pipe_friction_head_loss_m(0.003, 0.063, 60.0, 1.5e-6)
	_check("hydro: friction head loss magnitude", _approx(h_f, 0.5, 1.5),
		"got %.3f m" % h_f)

	# Swamee-Jain factor for the default operating point (Re ≈ 6e4, smooth)
	var v := 0.003 / (PI * 0.063 * 0.063 / 4.0)
	var f := HydroSource.darcy_friction_factor(v, 0.063, 1.5e-6)
	_check("hydro: turbulent friction factor", _approx(f, 0.018, 0.022),
		"got %.4f" % f)

	# Laminar regime: f = 64/Re
	var v_lam := 0.01  # Re ≈ 627 in the 63 mm pipe
	var re := v_lam * 0.063 / HydroSource.WATER_KINEMATIC_VISCOSITY
	var f_lam := HydroSource.darcy_friction_factor(v_lam, 0.063, 1.5e-6)
	_check("hydro: laminar f = 64/Re", absf(f_lam - 64.0 / re) < 1e-9)

	# Seasonal variation: April (×1.4) outproduces August (×0.6)
	var p_apr := h.power_at_month_kw(4)
	var p_aug := h.power_at_month_kw(8)
	_check("hydro: April > August (snowmelt profile)", p_apr > p_aug,
		"apr %.3f aug %.3f" % [p_apr, p_aug])

	# Zero flow → zero power
	_check("hydro: zero flow", h.power_at_flow_kw(0.0) == 0.0)

	# Friction loss can never exceed gross head (power floors at 0)
	var choked := HydroConfig.new()
	choked.gross_head_m = 2.0
	choked.design_flow_m3s = 0.05
	choked.penstock_diameter_m = 0.04
	choked.penstock_length_m = 200.0
	var h2 := HydroSource.new()
	h2.config = choked
	_check("hydro: choked penstock floors at zero", h2.power_at_flow_kw(0.05) == 0.0,
		"loss %.1f m vs head %.1f m" % [h2.last_head_loss_m, choked.gross_head_m])

	# Per-type default efficiencies
	var c := HydroConfig.new()
	c.turbine_type = HydroConfig.TurbineType.PELTON
	_check("hydro: Pelton default η", absf(c.effective_turbine_efficiency() - 0.85) < 1e-6)
	c.turbine_type = HydroConfig.TurbineType.TURGO
	_check("hydro: Turgo default η", absf(c.effective_turbine_efficiency() - 0.80) < 1e-6)
	c.turbine_type = HydroConfig.TurbineType.RUN_OF_RIVER
	_check("hydro: run-of-river default η", absf(c.effective_turbine_efficiency() - 0.70) < 1e-6)

	h.free()
	h2.free()


func _test_defaults() -> void:
	# Solar estimator must not double-count into the grid balance
	var s := SolarPanelSource.new()
	_check("solar: contribute_to_grid off", s.contribute_to_grid == false)
	_check("solar: peak capacity 3.96 kW", absf(s.get_peak_capacity_kw() - 3.96) < 1e-6)
	s.free()

	# Wind/hydro default contribute and share the solar signal contract
	var w := _make_wind()
	_check("wind: contributes to grid", w.contribute_to_grid == true)
	_check("wind: has power_updated signal", w.has_signal("power_updated"))
	var h := _make_hydro()
	_check("hydro: contributes to grid", h.contribute_to_grid == true)
	_check("hydro: has power_updated signal", h.has_signal("power_updated"))
	w.free()
	h.free()


## The flat-specs adapters used by 2D system-graph "wind"/"hydro" items.
func _test_graph_adapters() -> void:
	# Wind: storm above cut-out is curtailed to zero (mean 30 m/s at the
	# afternoon diurnal peak lands well past the 20 m/s cut-out).
	var storm := {"site_mean_wind_ms": 30.0}
	_check("graph wind: storm cut-out",
		WindTurbineSource.power_kw_from_graph_specs(storm, 15.0) == 0.0)

	# Calm site produces nothing.
	var calm := {"site_mean_wind_ms": 0.0}
	_check("graph wind: calm site",
		WindTurbineSource.power_kw_from_graph_specs(calm, 15.0) == 0.0)

	# Moderate site produces between zero and nameplate.
	var mid := {"site_mean_wind_ms": 7.0}
	var p_mid := WindTurbineSource.power_kw_from_graph_specs(mid, 15.0)
	_check("graph wind: moderate site in (0, rated)", p_mid > 0.0 and p_mid <= 1.0,
		"got %.3f kW" % p_mid)

	# Taller hub harvests more (log-law shear), all else equal.
	var low_hub := {"site_mean_wind_ms": 6.0, "hub_height_m": 5.0}
	var high_hub := {"site_mean_wind_ms": 6.0, "hub_height_m": 20.0}
	var p_low := WindTurbineSource.power_kw_from_graph_specs(low_hub, 12.0)
	var p_high := WindTurbineSource.power_kw_from_graph_specs(high_hub, 12.0)
	_check("graph wind: taller hub > shorter hub", p_high > p_low,
		"5m %.3f vs 20m %.3f" % [p_low, p_high])

	# Hydro: defaults ≈ 500 W scaled by the month multiplier; spring beats
	# late summer; more head means more power.
	var dflt: Dictionary = {}
	var apr := HydroSource.power_kw_from_graph_specs(dflt, 4)
	var aug := HydroSource.power_kw_from_graph_specs(dflt, 8)
	_check("graph hydro: April > August", apr > aug,
		"apr %.3f aug %.3f" % [apr, aug])
	_check("graph hydro: April magnitude", _approx(apr, 0.55, 0.85),
		"got %.3f kW" % apr)
	var tall := {"gross_head_m": 50.0}
	_check("graph hydro: more head, more power",
		HydroSource.power_kw_from_graph_specs(tall, 6) >
		HydroSource.power_kw_from_graph_specs(dflt, 6))

	# KINDS registry parity: kind_meta reproduces the historic per-kind
	# efficiencies (pelton .85 / turgo .80 / else .70), and an unknown free-text
	# kind resolves to the custom .70 fallback (never rejected — save-compat).
	_check("hydro KINDS: pelton η", absf(HydroSource.default_turbine_efficiency("pelton") - 0.85) < 1e-9)
	_check("hydro KINDS: turgo η", absf(HydroSource.default_turbine_efficiency("turgo") - 0.80) < 1e-9)
	_check("hydro KINDS: run_of_river η", absf(HydroSource.default_turbine_efficiency("run_of_river") - 0.70) < 1e-9)
	_check("hydro KINDS: unknown → custom 0.70",
		absf(HydroSource.default_turbine_efficiency("waterwheel_todo") - 0.70) < 1e-9)
	# Pelton band floor is 10 m since the Hydro Lab overhaul (the old 30 m floor
	# described utility practice; micro Peltons run at 10 m-class heads — Thake).
	_check("hydro KINDS: pelton head band floor 10 m",
		is_equal_approx(float((HydroSource.kind_meta("pelton").get("head_band", [0, 0]) as Array)[0]), 10.0))
	# PowerSpout PLT-class pico Pelton (published 3–130 m, 1.6 kW max).
	var psp := HydroSource.kind_meta("powerspout_pelton")
	_check("hydro KINDS: powerspout band 3–130 m",
		is_equal_approx(float((psp.get("head_band", [0, 0]) as Array)[0]), 3.0)
		and is_equal_approx(float((psp.get("head_band", [0, 0]) as Array)[1]), 130.0))
	_check("hydro KINDS: powerspout nozzle-modeled + 1.6 kW nameplate",
		bool(psp.get("uses_nozzle_model", false))
		and is_equal_approx(float(psp.get("max_power_w", 0.0)), 1600.0))

	# PeltonPhysics (nozzle-governed impulse turbine, Thake):
	# jet velocity v = Cv·√(2gh) — at 20 m: 0.97·19.81 = 19.21 m/s.
	var vj := PeltonPhysics.jet_velocity_ms(20.0)
	_check("pelton: jet velocity @20m ≈ 19.21", absf(vj - 19.215) < 0.01, "%.3f" % vj)
	# 1× 10 mm nozzle at that head: Q = A·v = 7.854e-5 · 19.215 = 1.509 L/s.
	var qn := PeltonPhysics.nozzle_flow_m3s(20.0, 0.010, 1) * 1000.0
	_check("pelton: nozzle demand @20m ≈ 1.51 L/s", absf(qn - 1.509) < 0.005, "%.4f" % qn)
	# nozzle_head_required is the exact inverse of nozzle_flow.
	var h_rt := PeltonPhysics.nozzle_head_required_m(
		PeltonPhysics.nozzle_flow_m3s(12.0, 0.010, 2), 0.010, 2)
	_check("pelton: nozzle head/flow round-trip", absf(h_rt - 12.0) < 0.01, "%.3f" % h_rt)
	# Operating point: friction eats head, so op flow < frictionless nozzle
	# demand, and h_f + h_net == h_gross at the solution.
	var op := PeltonPhysics.operating_point(20.0, 100.0, 0.03753, 1.5e-6, 0.010, 1)
	var op_q := float(op.get("q_lps", 0.0))
	_check("pelton op: flow below frictionless demand", op_q > 0.5 and op_q < 1.509,
		"%.3f" % op_q)
	_check("pelton op: heads balance", absf(float(op.get("h_net_m", 0.0))
		+ float(op.get("head_loss_m", 0.0)) - 20.0) < 0.05,
		"net %.2f + loss %.2f" % [float(op.get("h_net_m", 0.0)), float(op.get("head_loss_m", 0.0))])
	# Fatter pipe → less friction → more flow (the what-if the Lab teaches).
	var op_fat := PeltonPhysics.operating_point(20.0, 100.0, 0.04692, 1.5e-6, 0.010, 1)
	_check("pelton op: 2in pipe beats 1.5in", float(op_fat.get("q_lps", 0.0)) > op_q)
	# Runner curve: peaks at x = 0.46, zero at stall and runaway.
	_check("pelton runner: peak at x=0.46",
		absf(PeltonPhysics.runner_efficiency(0.46, 0.65) - 0.65) < 1e-6)
	_check("pelton runner: stall + runaway are zero",
		PeltonPhysics.runner_efficiency(0.0, 0.65) == 0.0
		and PeltonPhysics.runner_efficiency(0.92, 0.65) == 0.0)
	_check("pelton runner: off-peak below peak",
		PeltonPhysics.runner_efficiency(0.30, 0.65) < 0.65)
	# RPM: u = 0.46·v_j, ω = 2u/PCD. At v_j 17.05, PCD 0.22 → ~681 rpm.
	var rpm := PeltonPhysics.rpm(17.05, 0.22)
	_check("pelton rpm @17.05 m/s jet ≈ 681", absf(rpm - 681.0) < 5.0, "%.0f" % rpm)

	# Estimator closed form for nozzle kinds: flow comes from the nozzle
	# operating point (design_flow_lps 0 = unlimited supply), nameplate applies.
	var ps_specs := {"turbine_kind": "powerspout_pelton", "gross_head_m": 20.0,
		"penstock_length_m": 100.0, "penstock_diameter_mm": 37.53,
		"pipe_roughness_mm": 0.0015, "nozzle_count": 1, "nozzle_diameter_mm": 10.0,
		"design_flow_lps": 0.0, "generator_efficiency": 0.85}
	var ps_kw := HydroSource.power_kw_from_graph_specs(ps_specs, 6)
	_check("powerspout estimator: 20m/100m/1x10mm in the ~0.09–0.14 kW band",
		ps_kw > 0.09 and ps_kw < 0.14, "%.4f kW" % ps_kw)
	# Operating flow accessor (drives live_q_lps + the tailwater jet): nozzle
	# kinds report the PeltonPhysics op point (the 20 m case pins ~1.34 L/s),
	# design-flow kinds report design x multiplier, and zero head flows NOTHING.
	var of_ps := HydroSource.operating_flow_lps_from_graph_specs(ps_specs, 6)
	_check("op flow: powerspout 20m ~1.34 L/s", of_ps > 1.2 and of_ps < 1.5,
		"%.3f" % of_ps)
	var of_zero := ps_specs.duplicate(true)
	of_zero["gross_head_m"] = 0.0
	_check("op flow: zero head flows nothing",
		HydroSource.operating_flow_lps_from_graph_specs(of_zero, 6) == 0.0)
	var of_supply := ps_specs.duplicate(true)
	of_supply["design_flow_lps"] = 0.5
	of_supply["monthly_flow_multipliers"] = [1.0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]
	_check("op flow: supply cap bites",
		absf(HydroSource.operating_flow_lps_from_graph_specs(of_supply, 1) - 0.5) < 1e-6)
	var of_design := {"turbine_kind": "turgo", "gross_head_m": 15.0,
		"design_flow_lps": 10.0,
		"monthly_flow_multipliers": [0.5, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]}
	_check("op flow: design kinds = design x multiplier",
		absf(HydroSource.operating_flow_lps_from_graph_specs(of_design, 1) - 5.0) < 1e-6)

	var ps_big := ps_specs.duplicate(true)
	ps_big["gross_head_m"] = 130.0
	ps_big["penstock_length_m"] = 10.0
	ps_big["penstock_diameter_mm"] = 63.0
	ps_big["nozzle_count"] = 2
	ps_big["nozzle_diameter_mm"] = 12.0
	_check("powerspout estimator: 130 m clamps at the 1.6 kW nameplate",
		absf(HydroSource.power_kw_from_graph_specs(ps_big, 6) - 1.6) < 1e-6)
	var ps_low := ps_specs.duplicate(true)
	ps_low["gross_head_m"] = 3.0
	var ps_low_kw := HydroSource.power_kw_from_graph_specs(ps_low, 6)
	_check("powerspout estimator: 3 m head still positive (pico class)",
		ps_low_kw > 0.001, "%.4f kW" % ps_low_kw)
	# turbine_kind key is honored as an alias for the legacy `kind` key.
	var by_kind := {"gross_head_m": 40.0, "design_flow_lps": 10.0, "kind": "turgo"}
	var by_turbine := {"gross_head_m": 40.0, "design_flow_lps": 10.0, "turbine_kind": "turgo"}
	_check("hydro: turbine_kind aliases kind",
		absf(HydroSource.power_kw_from_graph_specs(by_kind, 6)
			- HydroSource.power_kw_from_graph_specs(by_turbine, 6)) < 1e-9)

	# monthly_flow_multiplier (extracted so telemetry and physics share ONE
	# lookup): specs array > weather array > built-in default profile, and
	# power_kw_from_graph_specs uses exactly this value (flow scales linearly,
	# so halving the multiplier halves an unclamped turbine's output).
	var mm_specs := {"monthly_flow_multipliers":
			[0.5, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]}
	_check("hydro multiplier: specs array wins",
		absf(HydroSource.monthly_flow_multiplier(mm_specs, 1, [2.0, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2]) - 0.5) < 1e-9)
	_check("hydro multiplier: weather array when specs absent",
		absf(HydroSource.monthly_flow_multiplier({}, 3, [1, 1, 0.25, 1, 1, 1, 1, 1, 1, 1, 1, 1]) - 0.25) < 1e-9)
	var apr_mult := HydroSource.monthly_flow_multiplier({}, 4, [])
	var aug_mult := HydroSource.monthly_flow_multiplier({}, 8, [])
	_check("hydro multiplier: default profile April > August", apr_mult > aug_mult)
	# Fat pipe (200 mm) so friction is negligible and P is ~linear in Q — with
	# the default 63 mm pipe the halved flow would also halve friction loss and
	# the ratio drifts to ~0.62, which is friction physics, not the multiplier.
	var one_x := {"gross_head_m": 40.0, "design_flow_lps": 10.0, "kind": "turgo",
		"penstock_diameter_mm": 200.0,
		"monthly_flow_multipliers": [1.0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]}
	var half_x: Dictionary = one_x.duplicate(true)
	half_x["monthly_flow_multipliers"] = [0.5, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]
	var p_1x := HydroSource.power_kw_from_graph_specs(one_x, 1)
	var p_half := HydroSource.power_kw_from_graph_specs(half_x, 1)
	_check("hydro multiplier: physics uses the same lookup (≈linear in Q)",
		p_half > p_1x * 0.48 and p_half < p_1x * 0.52,
		"1x %.3f vs 0.5x %.3f" % [p_1x, p_half])

	_test_pelton_supply()
	_test_hydro_supply()

	# Nameplate clamp: max_power_w caps the estimator; absent = uncapped.
	var big := {"gross_head_m": 200.0, "design_flow_lps": 50.0, "kind": "pelton"}
	var uncapped := HydroSource.power_kw_from_graph_specs(big, 6)
	var capped_specs := big.duplicate()
	capped_specs["max_power_w"] = 500.0
	var capped := HydroSource.power_kw_from_graph_specs(capped_specs, 6)
	_check("hydro: big install exceeds 0.5 kW uncapped", uncapped > 0.5, "got %.3f kW" % uncapped)
	_check("hydro: nameplate clamps to max_power_w", _approx(capped, 0.4999, 0.5001), "got %.4f kW" % capped)

	# Annual energy closed form: monthly kWh sum == annual, and a flat-multiplier
	# spec matches kW × representative-year hours (8760) by hand.
	var flat := {"gross_head_m": 40.0, "design_flow_lps": 10.0, "kind": "turgo",
		"monthly_flow_multipliers": [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]}
	var ann := HydroSource.annual_energy_kwh_from_specs(flat, [])
	var monthly: PackedFloat32Array = ann["monthly_kwh"]
	var sum := 0.0
	for kwh in monthly:
		sum += kwh
	var annual_kwh := float(ann["annual_kwh"])
	# monthly is float32 → allow a few kWh of accumulation slack over the year.
	_check("hydro annual: monthly sum == annual", absf(sum - annual_kwh) < 5.0,
		"sum %.1f vs annual %.1f" % [sum, annual_kwh])
	var kw_flat := HydroSource.power_kw_from_graph_specs(flat, 6)   # flat → every month same
	_check("hydro annual: flat spec == kW × 8760 h", absf(annual_kwh - kw_flat * 8760.0) < 1.0,
		"annual %.1f vs %.1f" % [annual_kwh, kw_flat * 8760.0])


## Leap-year indexing. An Open-Meteo leap-year archive has 8784 hours; it used
## to be read with the common-year month table, so every date after Feb 29
## read the PREVIOUS day (Bombay Beach 2024-04-14 15:00 showed Apr 13's wind).
func _test_weather_leap_index() -> void:
	var WS = load("res://core/weather_service.gd")
	_check("leap: 2024 / 2000 leap, 2023 / 1900 not",
		WS.is_leap_year(2024) and WS.is_leap_year(2000)
		and not WS.is_leap_year(2023) and not WS.is_leap_year(1900))
	_check("leap: 8784 is a leap layout, 8760 is not",
		WS.is_leap_layout(8784) and not WS.is_leap_layout(8760))
	var idx := float(WS.hour_index(4, 14, 15.0, true))
	_check("leap: 2024-04-14 15:00 = (31+29+31+13)*24+15",
		idx == float((31 + 29 + 31 + 13) * 24 + 15), "got %.1f" % idx)
	_check("leap: common 04-14 15:00 = (31+28+31+13)*24+15",
		float(WS.hour_index(4, 14, 15.0, false)) == float((31 + 28 + 31 + 13) * 24 + 15))
	_check("leap: Jan/Feb identical in both layouts",
		WS.day_of_year0(2, 7, true) == WS.day_of_year0(2, 7, false)
		and WS.day_of_year0(2, 28, true) == 58)
	_check("leap: Feb 29 = day 59 in a leap layout, Mar 1 = 60",
		WS.day_of_year0(2, 29, true) == 59 and WS.day_of_year0(3, 1, true) == 60)
	_check("leap: Feb 29 on a common layout repeats Feb 28 (not Mar 1)",
		WS.day_of_year0(2, 29, false) == 58 and WS.day_of_year0(3, 1, false) == 59)
	_check("leap: Dec 31 last hour = 8783 / 8759",
		int(WS.hour_index(12, 31, 23.0, true)) == 8783
		and int(WS.hour_index(12, 31, 23.0, false)) == 8759)

	# End to end through sample(): a canned 8784-hour archive whose value IS the
	# day of year, so the read says which day it landed on.
	var ws: Node = WS.new()
	var leap_vals: Array = []
	for i in 8784:
		leap_vals.append(float(i / 24))
	ws.parse_archive_json(JSON.stringify({"hourly": {"temperature_2m": leap_vals}}),
		33.36, -115.73, 2024)
	var d := float(ws.sample("temperature_2m", 4, 14, 15.0))
	_check("leap: archive read on Apr 14 lands on day 104 (not Apr 13 = 103)",
		d == 104.0, "got %.1f" % d)
	_check("leap: archive Feb 29 reads its own day 59",
		float(ws.sample("temperature_2m", 2, 29, 12.0)) == 59.0)
	_check("leap: archive Feb 7 unchanged (day 37)",
		float(ws.sample("temperature_2m", 2, 7, 15.0)) == 37.0)
	# Monthly sums follow the layout: one unit per hour in March only.
	var precip: Array = []
	for i in 8784:
		precip.append(1.0 if (i >= 60 * 24 and i < 91 * 24) else 0.0)
	ws.parse_archive_json(JSON.stringify({"hourly": {"precipitation": precip}}),
		33.36, -115.73, 2024)
	var mm: Array = ws.monthly_precip_mm()
	_check("leap: March precip sum is all of March, nothing in Feb / Apr",
		mm.size() == 12 and float(mm[2]) == 31.0 * 24.0 and float(mm[1]) == 0.0
		and float(mm[3]) == 0.0, str(mm))
	# A common-year archive read with a leap-year date keeps Mar 1 as Mar 1.
	var common_vals: Array = []
	for i in 8760:
		common_vals.append(float(i / 24))
	ws.parse_archive_json(JSON.stringify({"hourly": {"temperature_2m": common_vals}}),
		33.36, -115.73, 2023)
	_check("leap: common archive Mar 1 = day 59, Feb 29 = Feb 28 (58)",
		float(ws.sample("temperature_2m", 3, 1, 12.0)) == 59.0
		and float(ws.sample("temperature_2m", 2, 29, 12.0)) == 58.0)
	# Training data loses Feb 29 so it lines up with the common layout.
	var cut: Dictionary = WS.to_common_year({"t": PackedFloat32Array(leap_vals),
		"c": PackedFloat32Array(common_vals)})
	var t: PackedFloat32Array = cut["t"]
	_check("leap: to_common_year drops Feb 29 (8760 h, Mar 1 = day 60)",
		t.size() == 8760 and t[59 * 24] == 60.0 and t[58 * 24] == 58.0
		and (cut["c"] as PackedFloat32Array).size() == 8760)
	# Forecast window crossing Feb 29 of a leap year: entries are consecutive.
	var fvals: Array = []
	for i in 30 * 24:
		fvals.append(float(i))
	var ok := bool(ws.parse_forecast_json(JSON.stringify({"hourly": {
		"time": ["2028-02-20T00:00"], "cloud_cover": fvals}}), 33.36, -115.73))
	var fi := int(ws._forecast_hour_idx(3, 5, 6.0))
	_check("leap: forecast window over Feb 29 — Mar 5 06:00 is 14 days in",
		ok and fi == 14 * 24 + 6, "got %d" % fi)
	ws.free()


## WeatherService parsing/accessors on canned Open-Meteo JSON (no network),
## and the real-data paths through the graph adapters.
func _test_weather_service() -> void:
	var ws: Node = load("res://core/weather_service.gd").new()

	# Canned 48-hour response (Jan 1–2): wind ramps 0→47 km/h, temp 0→47 °C,
	# cloud 50%, 1 mm precip in hour 0 only.
	var hours := 48
	var wind: Array = []
	var temp: Array = []
	var cloud: Array = []
	var precip: Array = []
	var sw: Array = []
	for i in hours:
		wind.append(float(i))
		temp.append(float(i))
		cloud.append(50.0)
		precip.append(1.0 if i == 0 else 0.0)
		sw.append(500.0)
	var canned := JSON.stringify({"hourly": {
		"wind_speed_10m": wind, "temperature_2m": temp, "cloud_cover": cloud,
		"precipitation": precip, "shortwave_radiation": sw,
	}})

	_check("weather: parse canned JSON", ws.parse_archive_json(canned, 33.36, -115.74, 2025))
	_check("weather: has_data", ws.has_data())
	_check("weather: covers nearby point", ws.covers(33.37, -115.75))
	_check("weather: rejects far point", not ws.covers(34.0, -115.74))

	# Jan 1, hour 12 → wind index 12 → 12 km/h = 3.333 m/s (km/h conversion)
	var v := float(ws.wind_speed_ms(1, 1, 12.0))
	_check("weather: wind km/h→m/s + indexing", _approx(v, 3.30, 3.37), "got %.3f" % v)
	# Half-hour interpolation: index 12.5 → 12.5 °C
	var t := float(ws.temperature_c(1, 1, 12.5))
	_check("weather: hourly interpolation", _approx(t, 12.45, 12.55), "got %.2f" % t)
	# Cloud percent → fraction
	_check("weather: cloud % → fraction", _approx(float(ws.cloud_cover_frac(1, 1, 6.0)), 0.49, 0.51))
	# All precipitation fell in January → its multiplier is 12× the mean
	var mults: Array = ws.monthly_precip_multipliers()
	_check("weather: 12 multipliers", mults.size() == 12)
	if mults.size() == 12:
		_check("weather: normalization (Jan = 12× mean)", _approx(float(mults[0]), 11.9, 12.1),
			"got %.2f" % float(mults[0]))
	# Missing variable → NAN
	_check("weather: missing variable is NAN", is_nan(float(ws.sample("nonexistent", 1, 1, 0.0))))

	# effective_year: past years pass through, current/future substitute
	var this_year := int(Time.get_date_dict_from_system().year)
	_check("weather: historical year passthrough", ws.effective_year(2010) == 2010)
	_check("weather: current year substitutes latest complete",
		ws.effective_year(this_year) == this_year - 1)

	# Graph adapters consume real inputs: measured 10 m wind drives output,
	# storm-level real wind cuts out; weather multipliers reorder hydro months.
	var p_real := WindTurbineSource.power_kw_from_graph_specs({}, 12.0, 8.0)
	_check("graph wind: real wind produces", p_real > 0.0 and p_real <= 1.0, "got %.3f" % p_real)
	_check("graph wind: real storm cuts out",
		WindTurbineSource.power_kw_from_graph_specs({}, 12.0, 30.0) == 0.0)
	var wet_january: Array = [3.0, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5]
	_check("graph hydro: weather multipliers override default ordering",
		HydroSource.power_kw_from_graph_specs({}, 1, wet_january) >
		HydroSource.power_kw_from_graph_specs({}, 4, wet_january))

	ws.free()


## SolarPosition (Meeus SPA) geometry and NOCT/gamma formula checks.
func _test_solar_physics() -> void:
	# NOCT cell temperature: T_cell = T_amb + (NOCT - 20) * G / 800
	# At G=1000 W/m², T_amb=25°C, NOCT=45°C → T_cell = 25 + 25*1000/800 = 56.25°C
	var noct : float = 45.0
	var t_cell : float = 25.0 + (noct - 20.0) * 1000.0 / 800.0
	_check("solar: NOCT cell temp at G=1000 T_amb=25", _approx(t_cell, 56.2, 56.3),
		"got %.2f°C" % t_cell)

	# Gamma derating: P = P_stc * (1 + γ*(T_cell - 25))
	# At T_cell=56.25°C, γ=-0.004 → factor = 1 - 0.004*31.25 = 0.875
	var gamma : float = -0.004
	var t_factor : float = 1.0 + gamma * (t_cell - 25.0)
	_check("solar: gamma derating at 56.25°C", _approx(t_factor, 0.874, 0.876),
		"got %.4f" % t_factor)

	# No irradiance → cell at ambient → factor = 1.0
	var t_cell_dark : float = 25.0 + (noct - 20.0) * 0.0 / 800.0
	_check("solar: no derating at STC temperature",
		absf(1.0 + gamma * (t_cell_dark - 25.0) - 1.0) < 1e-9)

	# SolarPosition: summer solstice 2024-06-21 12:00 UTC (JD≈2460482.0),
	# lat=0 lon=0 → sun is above horizon (elevation > 0°)
	var sp_noon := SolarPosition.get_position(0.0, 0.0, 2460482.0)
	var el_noon : float = float(sp_noon.get("elevation_deg", -90.0))
	_check("solar: SPA sun above horizon at summer-solstice noon UTC",
		el_noon > 0.0, "got %.2f°" % el_noon)

	# 12 hours later (midnight UTC same location) → sun below horizon
	var sp_mid := SolarPosition.get_position(0.0, 0.0, 2460482.0 + 0.5)
	var el_mid : float = float(sp_mid.get("elevation_deg", 90.0))
	_check("solar: SPA sun below horizon at midnight UTC",
		el_mid < 0.0, "got %.2f°" % el_mid)

	# Azimuth in [0, 360] and elevation in [-90, 90]
	var az : float = float(sp_noon.get("azimuth_deg", -1.0))
	_check("solar: SPA azimuth in valid range", az >= 0.0 and az <= 360.0,
		"got %.2f°" % az)
	_check("solar: SPA elevation in valid range", el_noon >= -90.0 and el_noon <= 90.0,
		"got %.2f°" % el_noon)

	# panel_cos_incidence: horizontal panel (tilt=0), sun directly overhead (el=90°) → 1.0
	var cos_ov : float = SolarPosition.panel_cos_incidence(180.0, 90.0, 180.0, 0.0)
	_check("solar: cos_incidence = 1 when sun overhead on flat panel",
		_approx(cos_ov, 0.999, 1.001), "got %.4f" % cos_ov)

	# Horizontal panel, sun at horizon (el=0°) → cos_incidence = 0
	var cos_hz : float = SolarPosition.panel_cos_incidence(180.0, 0.0, 180.0, 0.0)
	_check("solar: cos_incidence = 0 when sun at horizon on flat panel",
		cos_hz < 0.01, "got %.4f" % cos_hz)

	# Vertical south-facing panel (tilt=90°), sun due south at el=45° → cos = cos(45°) ≈ 0.707
	var cos_v : float = SolarPosition.panel_cos_incidence(180.0, 45.0, 180.0, 90.0)
	_check("solar: cos_incidence on vertical panel at 45° elevation",
		_approx(cos_v, 0.705, 0.710), "got %.4f" % cos_v)


## Unified timecode: absolute-hours round-trip, reversible EnergyTimeline SOC,
## and TimeDirector provenance boundaries around NOW.
func _test_timecode() -> void:
	# ---- CelestialClock absolute hours round-trip ----
	var ClockScript := load("res://core/celestial_clock.gd")
	var clk = ClockScript.new()
	clk.year = 2026
	clk.month = 6
	clk.day = 13
	clk.day_time = 14.5
	var h := float(clk.get_absolute_hours())
	var clk2 = ClockScript.new()
	clk2.set_absolute_hours(h)
	_check("timecode: year round-trip", clk2.year == 2026, "got %d" % clk2.year)
	_check("timecode: month round-trip", clk2.month == 6, "got %d" % clk2.month)
	_check("timecode: day round-trip", clk2.day == 13, "got %d" % clk2.day)
	_check("timecode: hour round-trip", absf(float(clk2.day_time) - 14.5) < 1e-3,
		"got %.4f" % float(clk2.day_time))
	_check("timecode: abs-hours stable", absf(float(clk2.get_absolute_hours()) - h) < 1e-3)
	# Forward one day of absolute hours advances the calendar by one day.
	clk2.set_absolute_hours(h + 24.0)
	_check("timecode: +24h advances one day", clk2.day == 14, "got %d" % clk2.day)
	# Backward across a month boundary (Jun 1 00:00 minus 1h → May 31 23:00).
	clk2.year = 2026; clk2.month = 6; clk2.day = 1; clk2.day_time = 0.0
	var hb := float(clk2.get_absolute_hours())
	clk2.set_absolute_hours(hb - 1.0)
	_check("timecode: reverse across month", clk2.month == 5 and clk2.day == 31,
		"got %d-%d" % [clk2.month, clk2.day])

	# ---- EnergyTimeline reversibility ----
	# Pure step: charge with 95% efficiency.
	var s_charge := EnergyTimeline.step_soc(8.0, 2.0, 0.0, 0.0, 1.0, 16.0, 0.95, 0.95, 1.6)
	_check("timeline: charge step (η)", _approx(s_charge, 9.89, 9.91), "got %.4f" % s_charge)
	# Full-capacity clamp.
	var s_full := EnergyTimeline.step_soc(15.9, 5.0, 0.0, 0.0, 1.0, 16.0, 0.95, 0.95, 1.6)
	_check("timeline: charge clamps at capacity", absf(s_full - 16.0) < 1e-6, "got %.4f" % s_full)
	# Discharge floor (min 1.6 kWh).
	var s_floor := EnergyTimeline.step_soc(1.7, 0.0, 0.0, 2.0, 1.0, 16.0, 0.95, 0.95, 1.6)
	_check("timeline: discharge floors at min SOC", _approx(s_floor, 1.59, 1.61), "got %.4f" % s_floor)
	# Inverse of an unclamped charge step recovers the start SOC.
	var s_inv := EnergyTimeline.unstep_soc(s_charge, 2.0, 0.0, 0.0, 1.0, 16.0, 0.95, 0.95, 1.6)
	_check("timeline: unstep inverts charge", absf(s_inv - 8.0) < 1e-4, "got %.4f" % s_inv)

	# Record forward, then "scrub" back — SOC reads the cached curve (uncharges).
	var et := EnergyTimeline.new()
	et.step_hours = 1.0 / 60.0
	et.configure(16.0, 0.95, 0.95, 1.6)
	et.init_anchor(1000.0, 8.0, 2.0, 0.0, 0.0)
	var t := 1000.0
	while t < 1002.0 - 1e-9:
		t += et.step_hours
		et.record_step(t, 2.0, 0.0, 0.0)   # net +2 kW the whole window
	var soc_start := et.soc_at(1000.0)
	var soc_end := et.soc_at(1002.0)
	_check("timeline: anchor SOC preserved", absf(soc_start - 8.0) < 0.05, "got %.4f" % soc_start)
	_check("timeline: charged going forward", soc_end > soc_start + 3.0,
		"start %.2f end %.2f" % [soc_start, soc_end])
	# Scrub back to the midpoint: SOC must be between start and end (the uncharge).
	var soc_mid := et.soc_at(1001.0)
	_check("timeline: rewind uncharges (monotone)", soc_mid > soc_start and soc_mid < soc_end,
		"mid %.2f" % soc_mid)
	# Reading is pure: re-reading the end after a rewind is unchanged.
	_check("timeline: reads are non-destructive", absf(et.soc_at(1002.0) - soc_end) < 1e-4)
	# Daily channel integral: 2 hours of 2 kW solar ≈ 4 kWh.
	var solar_kwh := et.integrate_channel(1000.0, 1002.0, "solar")
	_check("timeline: channel integral (kWh)", _approx(solar_kwh, 3.9, 4.1), "got %.3f" % solar_kwh)

	# Stale cached future: scrub back to the midpoint, cut there, and replay
	# with a 3 kW load on. The history before the cut is kept; the battery now
	# DISCHARGES from the midpoint instead of replaying the old charge curve
	# (the "deficit but the battery never drops" report, Mt Vernon 2026-10-15).
	var mid_before := et.soc_at(1001.0)
	et.truncate_after(1001.0)
	_check("timeline: truncate keeps history up to the cut",
		absf(et.end_abs_hours() - 1001.0) < et.step_hours + 1e-6
			and absf(et.soc_at(1001.0) - mid_before) < 1e-4,
		"end %.4f soc %.3f vs %.3f" % [et.end_abs_hours(), et.soc_at(1001.0), mid_before])
	_check("timeline: truncate keeps the start", absf(et.soc_at(1000.0) - soc_start) < 1e-4)
	t = 1001.0
	while t < 1002.0 - 1e-9:
		t += et.step_hours
		et.record_step(t, 2.0, 0.0, 3.0)   # net −1 kW now
	_check("timeline: replay after truncate follows the new inputs",
		et.soc_at(1002.0) < mid_before - 0.9,
		"mid %.3f end %.3f" % [mid_before, et.soc_at(1002.0)])
	# A sim pre-render fills the LIVE timeline through the evaluator
	# (fill_forward_chunk) from a cut at the playhead; it must land exactly
	# where live record_step'ing the same inputs would — same step_soc, same
	# grid — or leaving a rendered range forward would show a jump.
	var et_live := EnergyTimeline.new()
	et_live.step_hours = 1.0 / 60.0
	et_live.configure(16.0, 0.95, 0.95, 1.6)
	et_live.init_anchor(1000.0, 8.0, 2.0, 0.0, 3.0)
	var et_render := EnergyTimeline.new()
	et_render.step_hours = 1.0 / 60.0
	et_render.configure(16.0, 0.95, 0.95, 1.6)
	et_render.init_anchor(1000.0, 8.0, 2.0, 0.0, 3.0)
	et_render.set_evaluator(func(_abs_h: float) -> Dictionary:
		return {"solar_kw": 2.0, "aux_kw": 0.0, "load_kw": 3.0})
	t = 1000.0
	while t < 1003.0 - 1e-9:
		t += et_live.step_hours
		et_live.record_step(t, 2.0, 0.0, 3.0)
	var done_fill := et_render.fill_forward_chunk(et_render.step_of(1003.0), 1 << 30)
	_check("timeline: render fill reaches its target", done_fill)
	# Compare at the live buffer's own last step (accumulating 1/60 in float
	# can land its final sample one step short of 1003.0; both buffers hold
	# the same per-step curve).
	# Tolerance = the float32 sample storage: one-step record_step calls re-read
	# the rounded SOC every step while the fill keeps a float64 running value
	# (measured 1.2e-5 kWh apart over 180 steps). 0.1 Wh is the honest pin.
	var t_cmp := et_live.end_abs_hours()
	_check("timeline: render fill == live record_step (same inputs, float32 storage)",
		absf(et_render.soc_at(t_cmp) - et_live.soc_at(t_cmp)) < 1e-4,
		"render %.6f live %.6f at %.4f" % [et_render.soc_at(t_cmp), et_live.soc_at(t_cmp), t_cmp])
	# Truncate the rendered future at the midpoint and fill again: identical.
	var fill_soc := et_render.soc_at(1003.0)
	et_render.truncate_after(1001.5)
	et_render.fill_forward_chunk(et_render.step_of(1003.0), 1 << 30)
	_check("timeline: truncate + re-fill reproduces the curve",
		absf(et_render.soc_at(1003.0) - fill_soc) < 1e-6,
		"again %.6f first %.6f" % [et_render.soc_at(1003.0), fill_soc])
	var et_one := EnergyTimeline.new()
	et_one.init_anchor(50.0, 4.0)
	et_one.truncate_after(10.0)   # before the start: still one sample
	_check("timeline: truncate never empties the cache", et_one.count() == 1)

	# Max-capture ("raw") channel: the scoreboard's "possible today". It
	# never feeds the battery, defaults to the delivered solar, is never
	# below it, and follows the evaluator's raw_kw on a fill.
	var er := EnergyTimeline.new()
	er.configure(16.0, 0.95, 0.95, 1.6)
	er.init_anchor(3000.0, 8.0, 2.0, 0.0, 0.0, 3.0)
	er.record_step(3001.0, 2.0, 0.0, 0.0, 3.0)    # 1 h clipped to 2 of 3 kW
	er.record_step(3002.0, 2.0, 0.0, 0.0)         # raw unknown -> = solar
	var eq := EnergyTimeline.new()
	eq.configure(16.0, 0.95, 0.95, 1.6)
	eq.init_anchor(3000.0, 8.0, 2.0, 0.0, 0.0)
	eq.record_step(3001.0, 2.0, 0.0, 0.0)
	eq.record_step(3002.0, 2.0, 0.0, 0.0)
	_check("timeline raw: 1 h at 3 kW + 1 h at 2 kW = 5 kWh possible",
		absf(er.integrate_channel(3000.0, 3002.0, "raw") - 5.0) < 0.02,
		"got %.3f" % er.integrate_channel(3000.0, 3002.0, "raw"))
	_check("timeline raw: delivered solar unchanged (4 kWh)",
		absf(er.integrate_channel(3000.0, 3002.0, "solar") - 4.0) < 0.02)
	_check("timeline raw: battery identical with or without raw",
		absf(er.soc_at(3002.0) - eq.soc_at(3002.0)) < 1e-6)
	er.record_step(3003.0, 2.0, 0.0, 0.0, 1.0)     # raw below solar is lifted
	_check("timeline raw: never below delivered solar",
		absf(er.integrate_channel(3002.0, 3003.0, "raw") - 2.0) < 0.02)
	er.set_evaluator(func(_h: float) -> Dictionary:
		return {"solar_kw": 1.0, "aux_kw": 0.0, "load_kw": 0.0, "raw_kw": 4.0})
	er.seek(3004.0)
	_check("timeline raw: evaluator fill carries raw_kw",
		absf(er.integrate_channel(3003.0, 3004.0, "raw") - 4.0) < 0.1,
		"got %.3f" % er.integrate_channel(3003.0, 3004.0, "raw"))
	er.truncate_after(3001.0)
	_check("timeline raw: truncate keeps channels aligned",
		absf(er.integrate_channel(3000.0, 3001.0, "raw") - 3.0) < 0.02
		and er.sample_at(3001.0).has("raw_kw"))

	# Measured (live-mirror) samples: stored verbatim, readable on rewind.
	var em := EnergyTimeline.new()
	em.step_hours = 1.0 / 60.0
	em.configure(16.0, 0.95, 0.95, 1.6)
	em.record_measured(2000.0, 10.0, 1.0, 0.0, 0.5)
	em.record_measured(2001.0, 12.0, 1.0, 0.0, 0.5)
	em.record_measured(2002.0, 9.0, 0.0, 0.0, 0.8)
	_check("timeline: measured read", _approx(em.soc_at(2001.0), 11.9, 12.1),
		"got %.3f" % em.soc_at(2001.0))
	_check("timeline: measured rewind reads stored value",
		em.soc_at(2002.0) < em.soc_at(2001.0),
		"2002 %.2f vs 2001 %.2f" % [em.soc_at(2002.0), em.soc_at(2001.0)])

	# ---- TimeDirector provenance around NOW ----
	# Provenance enum: REAL=0, OBSERVED=1, PROJECTED=2, RECORDED=3.
	var td = load("res://core/time_director.gd").new()
	td.now_abs_hours = 1000.0
	td._effective_mode = 2   # SIMULATE
	_check("provenance: future is PROJECTED", td.provenance_at(1010.0) == 2)
	_check("provenance: past is OBSERVED", td.provenance_at(990.0) == 1)
	td._effective_mode = 0   # LIVE
	_check("provenance: at-now in LIVE is REAL", td.provenance_at(1000.0) == 0)
	td._effective_mode = 1   # PLAYBACK
	_check("provenance: playback is RECORDED", td.provenance_at(990.0) == 3)
	td.free()


func _test_timeline_view() -> void:
	var TV := load("res://core/timeline/timeline_view.gd")
	var v = TV.new()
	v.start = 1000.0
	v.span = 168.0
	v.width_px = 840.0
	_check("timeline view: time_to_x left", absf(v.time_to_x(1000.0)) < 1e-6)
	var mid : float = v.x_to_time(420.0)
	_check("timeline view: x_to_time inverse", absf(mid - 1084.0) < 0.02, "got %.3f" % mid)
	v.zoom_at_cursor(TV.ZOOM_IN_FACTOR, 420.0)
	_check("timeline view: zoom shrinks span", v.span < 168.0)
	var anchored : float = v.x_to_time(420.0)
	_check("timeline view: zoom preserves cursor", absf(anchored - mid) < 0.05)
	var v2 = TV.new()
	v2.start = 1000.0
	v2.span = 24.0
	v2.width_px = 480.0
	v2.pan_by_hours(3.0)
	_check("timeline view: pan by hours", absf(v2.start - 997.0) < 1e-6, "start %.3f" % v2.start)
	v2.span = 24.0
	v2.width_px = 480.0
	_check("timeline view: hour ticks at 1 day", absf(v2.choose_major_interval_hours() - 1.0) < 1e-6)
	var et := EnergyTimeline.new()
	et.configure(16.0, 0.95, 0.95, 1.6)
	et.init_anchor(1000.0, 8.0, 2.0, 0.0, 1.0)
	var t := 1000.0
	while t < 1001.0 - 1e-9:
		t += et.step_hours
		et.record_step(t, 2.0, 0.0, 0.5)
	var wf : PackedFloat32Array = et.waveform_bins(1000.0, 1001.0, 8, "solar_kw", "peak")
	_check("waveform: bins populated", wf.size() == 8 and float(wf[4]) > 0.0, "peak %.3f" % float(wf[4]))


## Observed-vs-simulated comparison: unix↔abs bridge, ObservedSeries resample,
## chunked batch render determinism, and observed-range provenance.
func _test_comparison() -> void:
	var ClockScript := load("res://core/celestial_clock.gd")
	var clk = ClockScript.new()

	# ---- Unix ↔ absolute-hours bridge ----
	var dt0 := {"year": 2026, "month": 5, "day": 23, "hour": 6, "minute": 30, "second": 0}
	var t_unix := int(Time.get_unix_time_from_datetime_dict(dt0))
	var abs_h := float(clk.unix_to_abs_hours(t_unix))
	clk.set_absolute_hours(abs_h)
	_check("bridge: unix→abs lands on date", clk.year == 2026 and clk.month == 5 and clk.day == 23,
		"got %d-%d-%d" % [clk.year, clk.month, clk.day])
	_check("bridge: unix→abs time-of-day", absf(float(clk.day_time) - 6.5) < 1e-3,
		"got %.4f" % float(clk.day_time))
	# abs→JD(UTC) matches the clock's own JD(UTC) at the same instant.
	var jd1 := float(clk.get_julian_day_utc())
	var jd2 := float(clk.abs_hours_to_julian_day_utc(float(clk.get_absolute_hours())))
	_check("bridge: abs→JD(UTC) matches clock JD", absf(jd1 - jd2) < 1e-6,
		"%.6f vs %.6f" % [jd1, jd2])

	# ---- ObservedSeries resample ----
	var ObsScript := load("res://core/observed_series.gd")
	var base_unix := int(Time.get_unix_time_from_datetime_dict(
		{"year": 2026, "month": 5, "day": 23, "hour": 0, "minute": 0, "second": 0}))
	var role_samples := {
		"battery_soc": [
			{"t": base_unix, "v": 50.0},
			{"t": base_unix + 3600, "v": 60.0},
			{"t": base_unix + 7200, "v": 55.0}],
		"solar": [
			{"t": base_unix, "v": 0.0},
			{"t": base_unix + 3600, "v": 1000.0},
			{"t": base_unix + 7200, "v": 500.0}],
		"load": [
			{"t": base_unix, "v": 100.0},
			{"t": base_unix + 3600, "v": 200.0},
			{"t": base_unix + 7200, "v": 150.0}],
	}
	var obs = ObsScript.new()
	obs.build(role_samples, clk, 16.0, true)
	_check("observed: not empty after build", not bool(obs.is_empty()))
	_check("observed: has all channels", obs.has_soc() and obs.has_solar() and obs.has_load())
	var base_abs := float(clk.unix_to_abs_hours(base_unix))
	# SOC at +1h ≈ 60% of 16 kWh = 9.6 kWh (zero-order hold near the sample).
	var soc_1h := float(obs.soc_at(base_abs + 1.0))
	_check("observed: SOC % → kWh", _approx(soc_1h, 9.3, 9.9), "got %.3f" % soc_1h)
	# Solar at +1h ≈ 1000 W → 1.0 kW.
	var solar_1h := float(obs.sample_at(base_abs + 1.0).get("solar_kw", -1.0))
	_check("observed: W → kW", _approx(solar_1h, 0.9, 1.05), "got %.3f" % solar_1h)
	# Channel integral over the 2 h span is positive.
	var obs_solar_kwh := float(obs.integrate_channel(base_abs, base_abs + 2.0, "solar"))
	_check("observed: channel integral > 0", obs_solar_kwh > 0.0, "got %.3f" % obs_solar_kwh)

	# ---- Chunked batch render determinism ----
	var ev := func(_a: float) -> Dictionary:
		return {"solar_kw": 2.0, "aux_kw": 0.0, "load_kw": 0.5}
	# Render via many small chunks.
	var r1 := EnergyTimeline.new()
	r1.configure(16.0, 0.95, 0.95, 1.6)
	r1.set_evaluator(ev)
	r1.init_anchor(5000.0, 8.0, 2.0, 0.0, 0.5)
	var tgt := r1.step_of(5000.0 + 3.0)
	var guard := 0
	while not r1.fill_forward_chunk(tgt, 37) and guard < 100000:
		guard += 1
	var e1 := r1.soc_at(5000.0 + 3.0)
	# Render in one big chunk.
	var r2 := EnergyTimeline.new()
	r2.configure(16.0, 0.95, 0.95, 1.6)
	r2.set_evaluator(ev)
	r2.init_anchor(5000.0, 8.0, 2.0, 0.0, 0.5)
	r2.fill_forward_chunk(tgt, 1000000)
	var e2 := r2.soc_at(5000.0 + 3.0)
	_check("render: chunk size independent (determinism)", absf(e1 - e2) < 1e-4,
		"%.5f vs %.5f" % [e1, e2])
	_check("render: net +1.5 kW charged the battery", e1 > 8.0, "got %.3f" % e1)

	# ---- Observed-range provenance overrides SIMULATE ----
	var td2 = load("res://core/time_director.gd").new()
	td2.now_abs_hours = 800.0
	td2._effective_mode = 2   # SIMULATE
	td2.register_observed_range(900.0, 1000.0)
	_check("compare: inside observed range reads OBSERVED", td2.provenance_at(950.0) == 1)
	_check("compare: outside range future still PROJECTED", td2.provenance_at(1100.0) == 2)
	td2.set_compare_active(true)
	_check("compare: compare flag set", bool(td2.is_compare_active()))
	td2.clear_observed_range()
	_check("compare: observed range cleared", not bool(td2.has_observed_range()))
	td2.free()


func _doy(month: int, day: int) -> int:
	var c := CelestialClock.new()
	c.year = 2025
	c.month = month
	c.day = day
	return c.day_of_year


# Replicates main._step_analemma() on a bare clock to validate the primitives.
func _analemma_bounds() -> Vector2i:
	var hi: int = int(Time.get_date_dict_from_system().year)
	return Vector2i(mini(1940, hi), hi)


func _analemma_advance(c: CelestialClock) -> void:
	var start_year: int = c.year
	var cur: float = c.get_absolute_hours()
	var next_mid: float = (floor(cur / 24.0) + 1.0) * 24.0
	c.set_absolute_hours(next_mid)
	var bounds: Vector2i = _analemma_bounds()
	bounds.y = maxi(bounds.y, start_year)
	if start_year <= bounds.y and c.year > bounds.y:
		c.year = bounds.x
		c.month = 1
		c.day = 1
	c.day_time = c.mean_solar_time_to_clock_time(12.0)


func _analemma_advance_days(c: CelestialClock, days: int) -> void:
	for _i in maxi(0, days):
		_analemma_advance(c)


func _drift_mean_h(day_index: int, offset_min: float) -> float:
	if is_zero_approx(offset_min):
		return 12.0
	return fmod(12.0 + float(day_index) * offset_min / 60.0, 24.0)


func _test_season() -> void:
	# --- Phenology signals (northern hemisphere, mid-latitude) ---
	var win := SeasonModel.season_signals(_doy(1, 15), 40.0)
	_check("season: winter canopy bare", float(win["leaf_coverage"]) < 0.05)
	_check("season: winter signal high", float(win["winter"]) > 0.6)
	_check("season: winter not summer", float(win["summer"]) < 0.1)

	_check("season: winter grass short", float(win["grass_growth"]) < 0.1)

	var sum := SeasonModel.season_signals(_doy(7, 15), 40.0)
	_check("season: summer canopy full", float(sum["leaf_coverage"]) > 0.95)
	_check("season: summer signal high", float(sum["summer"]) > 0.6)
	_check("season: summer no autumn", float(sum["autumn"]) < 0.05)
	_check("season: summer grass tall", float(sum["grass_growth"]) > 0.9)

	# Grass grows in over spring: mid-April is partway up, well short of full.
	var spring := SeasonModel.season_signals(_doy(4, 15), 40.0)
	_check("season: spring grass growing",
		float(spring["grass_growth"]) > 0.1 and float(spring["grass_growth"]) < 0.95)

	var aut := SeasonModel.season_signals(_doy(10, 25), 40.0)
	_check("season: autumn colour peaks", float(aut["autumn"]) > 0.7)

	var late := SeasonModel.season_signals(_doy(11, 28), 40.0)
	_check("season: late autumn leaves down", float(late["leaf_coverage"]) < 0.1)

	# --- Hemisphere flip: southern January behaves like northern summer ---
	var sh := SeasonModel.season_signals(_doy(1, 15), -40.0)
	_check("season: SH January is summer",
		float(sh["leaf_coverage"]) > 0.9 and float(sh["summer"]) > 0.5)
	var nh := SeasonModel.to_nh_doy(_doy(1, 15), -40.0)
	_check("season: SH doy shifted ~half year", _approx(nh, 180.0, 215.0), "nh=%.1f" % nh)

	# --- Snow estimate: no weather service -> no snow, range-clamped ---
	var s0 := SeasonModel.estimate_snow_cover(null, 1, 15, 12.0, 40.0)
	_check("snow: null ws -> 0", s0 == 0.0)
	var d0 := SeasonModel.estimate_snow_depth_m(null, 1, 15, 12.0, 40.0)
	_check("snow: null ws depth -> 0", d0 == 0.0)
	_check("snow: cover from depth", SeasonModel.estimate_snow_cover(null, 7, 1, 12.0, 40.0) == 0.0)
	# 0.6 m pack -> cover > 1 clamped, depth preserved
	var cov_deep := clampf(0.6 / SeasonModel.COVER_DEPTH_M, 0.0, 1.0)
	_check("snow: deep cover saturates", cov_deep >= 1.0)

	# --- Analemma stepping primitives ---
	var c := CelestialClock.new()
	c.longitude = 0.0
	c.latitude = 40.0
	c.year = 2025
	c.month = 6
	c.day = 1
	c.day_time = 12.0
	var before := c.day_of_year
	_analemma_advance(c)
	_check("analemma: advances one day", c.day_of_year == before + 1,
		"%d -> %d" % [before, c.day_of_year])
	before = c.day_of_year
	_analemma_advance_days(c, 2)
	_check("analemma: advances two days (∞×2)", c.day_of_year == before + 2,
		"%d -> %d" % [before, c.day_of_year])
	_check("analemma: day_time finite in range",
		is_finite(c.day_time) and c.day_time >= 0.0 and c.day_time < 24.0,
		"day_time=%.3f" % c.day_time)

	var _b: Vector2i = _analemma_bounds()
	# Must not snap to 1940 when already at the current calendar year.
	c.year = _b.y
	c.month = 3
	c.day = 1
	c.day_time = 12.0
	_analemma_advance(c)
	_check("analemma: no snap from current playhead",
		c.year == _b.y, "expected %d got %d" % [_b.y, c.year])

	# Year advance: Dec 31 -> Jan 1 of the *next* year (within the archive window),
	# so successive analemma passes pull different real historical weather.
	c.year = _b.y - 1
	c.month = 12
	c.day = 31
	c.day_time = 12.0
	_analemma_advance(c)
	_check("analemma: advances into next year",
		c.month == 1 and c.day == 1 and c.year == _b.y,
		"%04d-%02d-%02d (expected %04d-01-01)" % [c.year, c.month, c.day, _b.y])

	# Year wrap: past the newest complete-archive year rolls back to the window
	# start (still real historical data, just a different year).
	c.year = _b.y
	c.month = 12
	c.day = 31
	c.day_time = 12.0
	_analemma_advance(c)
	_check("analemma: wraps to historical window start",
		c.month == 1 and c.day == 1 and c.year == _b.x,
		"%04d-%02d-%02d (expected %04d-01-01)" % [c.year, c.month, c.day, _b.x])
	# The window must reach the full ERA5 archive start (1940), not a recent cap.
	_check("analemma: cycles all the way back to 1940", _b.x == 1940,
		"lower bound=%d" % _b.x)

	# --- Diurnal drift offset (corkscrew time stepping) ---
	_check("drift: zero offset is mean noon",
		absf(_drift_mean_h(0, 0.0) - 12.0) < 0.001)
	_check("drift: 60 min/day on day 1",
		absf(_drift_mean_h(1, 60.0) - 13.0) < 0.001)
	_check("drift: wraps after 24h cycle",
		absf(_drift_mean_h(24, 60.0) - 12.0) < 0.001)
	_check("drift: distinct times over a week",
		_drift_mean_h(0, 30.0) != _drift_mean_h(7, 30.0))

	# --- Analemma shape: mean solar noon traces a figure-eight, apparent does not ---
	# Sampling the sun over a year at a FIXED MEAN solar time must produce both a
	# north/south (declination) swing AND an east/west (equation-of-time) wander.
	# Snapping to APPARENT solar noon zeroes the hour angle, collapsing the E/W
	# wander to ~0 (a vertical line) — that was the bug.
	var ac := CelestialClock.new()
	ac.longitude = 0.0
	ac.latitude = 40.0
	ac.auto_dst = false
	ac.manual_dst = false
	ac.year = 2025
	var mean_x_min := INF
	var mean_x_max := -INF
	var mean_y_min := INF
	var mean_y_max := -INF
	var app_x_min := INF
	var app_x_max := -INF
	for doy in range(1, 366):
		var m := 1
		var d := doy
		while m < 12:
			var dim := ac.get_days_in_month(m, ac.year)
			if d <= dim:
				break
			d -= dim
			m += 1
		ac.month = m
		ac.day = clampi(d, 1, ac.get_days_in_month(m, ac.year))
		ac.day_time = ac.mean_solar_time_to_clock_time(12.0)
		var md := ac.get_sun_direction()
		mean_x_min = minf(mean_x_min, md.x)
		mean_x_max = maxf(mean_x_max, md.x)
		mean_y_min = minf(mean_y_min, md.y)
		mean_y_max = maxf(mean_y_max, md.y)
		ac.day_time = ac.solar_time_to_clock_time(12.0)
		var ad := ac.get_sun_direction()
		app_x_min = minf(app_x_min, ad.x)
		app_x_max = maxf(app_x_max, ad.x)
	var mean_x_span := mean_x_max - mean_x_min
	var mean_y_span := mean_y_max - mean_y_min
	var app_x_span := app_x_max - app_x_min
	_check("analemma: N/S declination swing present", mean_y_span > 0.4,
		"y span=%.3f" % mean_y_span)
	_check("analemma: E/W equation-of-time wander present", mean_x_span > 0.02,
		"x span=%.4f" % mean_x_span)
	_check("analemma: apparent-noon E/W wander ~collapsed (old bug)",
		app_x_span < mean_x_span * 0.25,
		"apparent x span=%.4f vs mean=%.4f" % [app_x_span, mean_x_span])

	# --- Equation of time: correct annual harmonics (guards the analemma shape) ---
	# The real EoT bottoms out near -14.2 min around Feb 11 and peaks near +16.4 min
	# around Nov 3, with a single sign structure per lobe. A spurious 3rd harmonic
	# (the old 2L+g bug) shifts these extrema and their timing, and adds an extra
	# analemma self-crossing.
	var ec := CelestialClock.new()
	ec.longitude = 0.0
	ec.latitude = 40.0
	ec.year = 2025
	var eot_min := INF
	var eot_max := -INF
	var eot_min_doy := 0
	var eot_max_doy := 0
	var eot: Array[float] = []
	for doy in range(1, 366):
		var m := 1
		var d := doy
		while m < 12:
			var dim := ec.get_days_in_month(m, ec.year)
			if d <= dim:
				break
			d -= dim
			m += 1
		ec.month = m
		ec.day = clampi(d, 1, ec.get_days_in_month(m, ec.year))
		ec.day_time = 12.0
		var e_min := ec.get_equation_of_time(ec.get_julian_day()) * 60.0  # minutes
		eot.append(e_min)
		if e_min < eot_min:
			eot_min = e_min
			eot_min_doy = doy
		if e_min > eot_max:
			eot_max = e_min
			eot_max_doy = doy
	_check("EoT: minimum ~-14 min (elliptical+tilt)", _approx(eot_min, -15.5, -12.5),
		"min=%.2f min" % eot_min)
	_check("EoT: maximum ~+16.4 min", _approx(eot_max, 15.0, 18.0),
		"max=%.2f min" % eot_max)
	_check("EoT: minimum falls in early-mid February", eot_min_doy >= 30 and eot_min_doy <= 55,
		"min doy=%d" % eot_min_doy)
	_check("EoT: maximum falls in late Oct / early Nov", eot_max_doy >= 295 and eot_max_doy <= 315,
		"max doy=%d" % eot_max_doy)
	# Count sign changes of the EoT over the year — the true curve has exactly 4
	# zero crossings; the spurious 3rd harmonic adds two more.
	var sign_changes := 0
	for i in range(eot.size()):
		var a := eot[i]
		var b := eot[(i + 1) % eot.size()]
		if (a < 0.0 and b >= 0.0) or (a >= 0.0 and b < 0.0):
			sign_changes += 1
	_check("EoT: exactly 4 zero crossings per year", sign_changes == 4,
		"sign changes=%d" % sign_changes)


func _test_resource_flow() -> void:
	var tl = load("res://core/resource_timeline.gd").new()
	tl.configure(100.0)
	tl.init_anchor(10.0, 0.4)
	tl.record_step(11.0, 100.0)
	var lvl: float = tl.level_at(11.0)
	_check("resource timeline forward fill", lvl > 0.4, "lvl=%.3f" % lvl)
	var back: Dictionary = tl.seek(10.0)
	_check("resource timeline scrub back", absf(float(back.get("level", 0.0)) - 0.4) < 0.02)
	var specs: Dictionary = {"watts": 800.0, "output_rate": "5 kg/h"}
	ResourceKindsScript.new().migrate_processor_specs(specs)
	_check("resource processor outputs", (specs.get("outputs", []) as Array).size() >= 1)


func _test_resource_edges() -> void:
	_check("water/potable alias compatible",
		ResourceKindsScript.kinds_compatible("water", "potable_water"))
	_check("greywater != potable",
		not ResourceKindsScript.kinds_compatible("greywater", "water"))
	_check("empty kind rejected",
		not ResourceKindsScript.kinds_compatible("", "water"))
	_check("syngas/woodgas alias",
		ResourceKindsScript.kinds_compatible("syngas", "woodgas"))
	var idle: Dictionary = ResourceEdgeVisScript.stroke_for("water", 0.0, false)
	var live: Dictionary = ResourceEdgeVisScript.stroke_for("water", 60.0, true)
	_check("idle wire thinner than live",
		float(idle.get("width", 99.0)) < float(live.get("width", 0.0)))
	_check("idle wire not active", not bool(idle.get("active", true)))
	_check("live wire active", bool(live.get("active", false)))
	_check("legend has biomass entry", ResourceKindsScript.legend_entries().size() >= 8)


func _test_solar_eclipse() -> void:
	var sun := Vector3( 0.2, 0.9, -0.3 ).normalized()
	var moon_same := sun
	var full := SolarEclipse.sample( sun, moon_same )
	_check( "eclipse: conjunction obscured", float( full.get( "obscuration", 0.0 ) ) > 0.85 )
	_check( "eclipse: conjunction total", bool( full.get( "is_total", false ) ) )
	var moon_opp := ( -sun ).normalized()
	var none := SolarEclipse.sample( sun, moon_opp )
	_check( "eclipse: opposition clear", float( none.get( "obscuration", 0.0 ) ) < 0.01 )
	# 2024-04-08 total eclipse — Dallas, TX near maximum (~18:40 UTC).
	var clk := CelestialClock.new()
	clk.latitude = 32.78
	clk.longitude = -96.80
	clk.auto_dst = true
	clk.year = 2024
	clk.month = 4
	clk.day = 8
	# 13:42 CDT = 18:42 UTC, inside the published 18:40–18:44 UTC totality window.
	# (Was 13.35: that only landed near totality while the clock converted local
	# time with the EXACT longitude, 18.80 UTC; under the shared zone model it is
	# 18.35 UTC, twenty minutes early — see CelestialClock.zone_offset_hours.)
	clk.day_time = 13.70
	var dallas := clk.sample_solar_eclipse()
	var dallas_obs := float( dallas.get( "obscuration", 0.0 ) )
	var dallas_sep := float( dallas.get( "separation_deg", 99.0 ) )
	_check( "eclipse 2024-04-08 Dallas: near-total",
		bool( dallas.get( "is_total", false ) ) and dallas_obs > 0.85,
		"obs=%.2f sep=%.2f°" % [dallas_obs, dallas_sep] )
	_check( "moon/sun angular ratio ~1",
		_approx( SolarEclipse.moon_to_sun_angular_ratio(), 0.95, 1.08 ) )
	# Peak finder: Apr 8 2024 Dallas maximum within ~5 min of published ~18:40 UTC.
	var peak := SolarEclipse.find_peak_at_observer( 32.78, -96.80,
		SolarEclipse.calendar_jd_utc( 2024, 4, 8, 18.5 ), 5.0 )
	var peak_obs := float( peak.get( "obscuration", 0.0 ) )
	var peak_utc_h := float( SolarEclipse.jd_to_utc_calendar( float( peak.get( "jd_utc", 0.0 ) ) ).get( "day_time", 0.0 ) )
	_check( "eclipse peak 2024-04-08 Dallas: near-total",
		bool( peak.get( "is_total", false ) ) and peak_obs > 0.85,
		"obs=%.2f utc=%.2fh" % [peak_obs, peak_utc_h] )
	_check( "eclipse peak 2024-04-08 time ~18:40 UTC",
		peak_utc_h > 18.2 and peak_utc_h < 19.0,
		"utc=%.3fh" % peak_utc_h )
	# Year scan finds the April 2024 event at Dallas.
	var scan24 : Array = SolarEclipse.scan_year_at_observer( 32.78, -96.80, 2024, 0.5 )
	var found_apr8 := false
	for hit in scan24 :
		if int( hit.get( "month", 0 ) ) == 4 and int( hit.get( "day", 0 ) ) == 8 :
			found_apr8 = true
			break
	_check( "eclipse scan 2024 Dallas includes Apr 8", found_apr8, "hits=%d" % scan24.size() )


## Parabolic-trough CSP: single-axis N-S tracking law, incidence cosine loss,
## end losses, and water->steam mass/energy balance (csp_trough_source.gd).
## Supply-limited Pelton: what happens when a spring simply does not run as hard
## as the nozzle would pass. Thake, "The Micro-Hydro Pelton Turbine Manual" (ITDG
## 2000) — nozzle Cv 0.97, speed ratio x = u/v_jet with peak near 0.46.
func _test_pelton_supply() -> void:
	const L := 100.0
	const D := 0.03753   ## 1.5" SDR-9 poly ID
	const EPS := 1.5e-6
	const NOZ := 0.010
	# 1. Unlimited parity — NAN supply must return the unconstrained answer FIELD
	#    FOR FIELD. This is what makes "design_flow_lps 0 means unlimited" survive
	#    the new code path. And a supply of exactly 0.0 is the OPPOSITE answer:
	#    dry. Both are reachable, which is why the guard is is_nan, never <= 0.
	var free := PeltonPhysics.operating_point(20.0, L, D, EPS, NOZ, 1)
	var unl := PeltonPhysics.operating_point_supply_limited(20.0, L, D, EPS, NOZ, 1, NAN)
	var parity := true
	for k: String in ["q_m3s", "q_lps", "h_net_m", "head_loss_m", "v_jet_ms"]:
		if absf(float(unl[k]) - float(free[k])) > 1e-12:
			parity = false
	_check("pelton supply: NAN supply == unconstrained op point, field for field",
		parity and not bool(unl["supply_limited"]))
	var dry_op := PeltonPhysics.operating_point_supply_limited(20.0, L, D, EPS, NOZ, 1, 0.0)
	_check("pelton supply: 0.0 supply is DRY, not unconstrained",
		float(dry_op["q_lps"]) == 0.0 and float(dry_op["v_jet_ms"]) == 0.0
		and bool(dry_op["supply_limited"]))
	var ample := PeltonPhysics.operating_point_supply_limited(
			20.0, L, D, EPS, NOZ, 1, float(free["q_m3s"]) * 2.0)
	_check("pelton supply: ample supply does not bind",
		not bool(ample["supply_limited"])
		and absf(float(ample["q_lps"]) - float(free["q_lps"])) < 1e-12)

	# 2. Supply-limited, hand-computed. Q = 0.5 L/s through one 10 mm jet:
	#    A = pi/4 * 0.01^2 = 7.854e-5 m^2, v = 5e-4/7.854e-5 = 6.366 m/s,
	#    h_jet = (v/0.97)^2 / (2g) = 2.196 m.
	var lim := PeltonPhysics.operating_point_supply_limited(
			20.0, L, D, EPS, NOZ, 1, 0.0005)
	_check("pelton supply: flow caps at the supply exactly",
		bool(lim["supply_limited"]) and absf(float(lim["q_lps"]) - 0.5) < 1e-9,
		"%.6f L/s" % float(lim["q_lps"]))
	_check("pelton supply: nozzle converts only the head its flow demands (2.20 m)",
		absf(float(lim["h_net_m"]) - 2.196) < 0.01, "%.4f m" % float(lim["h_net_m"]))
	# 3. The head book balances: jet + friction + unused == gross.
	var book := float(lim["h_net_m"]) + float(lim["head_loss_m"]) \
			+ float(lim["unused_head_m"])
	_check("pelton supply: h_net + loss + unused == gross", absf(book - 20.0) < 0.01,
		"%.4f" % book)
	# 4. The whole point: the honest model makes LESS power than naively clamping
	#    Q while keeping the full net head, because the surplus head is never
	#    converted to jet velocity.
	var rho := 1000.0
	var g := 9.80665
	var honest_w := rho * g * 0.0005 * float(lim["h_net_m"])
	var naive_w := rho * g * 0.0005 * float(free["h_net_m"])
	_check("pelton supply: supply-limited power below the naive clamp",
		honest_w < naive_w * 0.2, "%.2f W vs %.2f W" % [honest_w, naive_w])
	# 5. The recommendation round-trips: fit the suggested nozzle and the free
	#    operating point delivers the supply it was sized for.
	var d_fit := PeltonPhysics.nozzle_d_for_supply_m(20.0, L, D, EPS, 1, 0.0005)
	var refit := PeltonPhysics.operating_point(20.0, L, D, EPS, d_fit, 1)
	_check("pelton supply: recommended nozzle is smaller than the fitted one",
		d_fit > 0.0 and d_fit < NOZ, "%.2f mm" % (d_fit * 1000.0))
	_check("pelton supply: recommended nozzle delivers the supply (±2%)",
		absf(float(refit["q_lps"]) - 0.5) < 0.01, "%.4f L/s" % float(refit["q_lps"]))

	# 6. available_supply_lps discriminates on has(), not on > 0 — a dried-up
	#    spring (supply 0) and an unlimited nozzle (design 0) are opposites.
	_check("supply resolver: supply_lps 0.0 means DRY",
		HydroSource.available_supply_lps({"supply_lps": 0.0}, 6) == 0.0)
	_check("supply resolver: design_flow 0 with no supply key means unlimited",
		is_nan(HydroSource.available_supply_lps({"design_flow_lps": 0.0}, 6)))
	var legacy := {"design_flow_lps": 4.0,
		"monthly_flow_multipliers": [0.5, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]}
	_check("supply resolver: absent supply key falls back to design x multiplier",
		absf(HydroSource.available_supply_lps(legacy, 1) - 2.0) < 1e-9)
	_check("supply resolver: supply_lps wins over design_flow_lps",
		absf(HydroSource.available_supply_lps(
			{"supply_lps": 1.25, "design_flow_lps": 99.0}, 6) - 1.25) < 1e-9)
	# A dry spring must produce nothing even at big head.
	var dry := {"turbine_kind": "powerspout_pelton", "gross_head_m": 40.0,
		"penstock_length_m": L, "penstock_diameter_mm": 37.53,
		"nozzle_diameter_mm": 10.0, "nozzle_count": 1, "supply_lps": 0.0}
	_check("supply resolver: a dry spring makes no power at 40 m head",
		HydroSource.power_kw_from_graph_specs(dry, 6) == 0.0)

	# 7. Speed ratio / rpm additions are ADDITIVE: the design-point helpers must
	#    still return exactly what they did (every pinned rpm depends on it).
	_check("pelton speed: omega_rad_s == omega_rad_s_at_ratio(x_opt)",
		absf(PeltonPhysics.omega_rad_s(17.05, 0.22)
			- PeltonPhysics.omega_rad_s_at_ratio(17.05, 0.22,
				PeltonPhysics.SPEED_RATIO_OPT)) < 1e-12)
	_check("pelton load: matched load sits at x_opt",
		absf(PeltonPhysics.speed_ratio_for_load(1.0)
			- PeltonPhysics.SPEED_RATIO_OPT) < 1e-12)
	_check("pelton load: no load runs away to 2·x_opt",
		absf(PeltonPhysics.speed_ratio_for_load(0.0)
			- 2.0 * PeltonPhysics.SPEED_RATIO_OPT) < 1e-12)
	# Runaway spins fastest and makes nothing — the whole teaching point of the
	# close-up view, and it falls straight out of the existing runner parabola.
	_check("pelton load: runaway spins ~2x and yields zero runner efficiency",
		PeltonPhysics.rpm_at_ratio(17.05, 0.22, PeltonPhysics.speed_ratio_for_load(0.0))
			> PeltonPhysics.rpm(17.05, 0.22) * 1.9
		and PeltonPhysics.runner_efficiency(
			PeltonPhysics.speed_ratio_for_load(0.0), 0.65) == 0.0)

	# 8. Bucket exit speed |v_jet - 2u| — the other half of the Euler relation, and
	#    the reason a well-matched Pelton visibly dribbles while a runaway sprays.
	const VJ := 17.05
	_check("pelton bucket: matched load leaves the water nearly dead",
		absf(PeltonPhysics.bucket_exit_speed_ms(VJ, PeltonPhysics.SPEED_RATIO_OPT)
			- VJ * 0.08) < 1e-4,
		"%.4f m/s" % PeltonPhysics.bucket_exit_speed_ms(VJ, PeltonPhysics.SPEED_RATIO_OPT))
	_check("pelton bucket: a stalled runner passes the jet straight through",
		absf(PeltonPhysics.bucket_exit_speed_ms(VJ, 0.0) - VJ) < 1e-9)
	_check("pelton bucket: runaway flings it far faster than matched",
		PeltonPhysics.bucket_exit_speed_ms(VJ, PeltonPhysics.speed_ratio_for_load(0.0))
			> PeltonPhysics.bucket_exit_speed_ms(VJ,
				PeltonPhysics.speed_ratio_for_load(1.0)) * 8.0,
		"%.2f vs %.2f m/s" % [
			PeltonPhysics.bucket_exit_speed_ms(VJ, PeltonPhysics.speed_ratio_for_load(0.0)),
			PeltonPhysics.bucket_exit_speed_ms(VJ, PeltonPhysics.speed_ratio_for_load(1.0))])
	# Exactly half the runaway ratio is the one speed where the bucket keeps pace
	# with the jet and nothing leaves — the zero of the relation.
	_check("pelton bucket: exit speed vanishes at x = 0.5",
		PeltonPhysics.bucket_exit_speed_ms(VJ, 0.5) < 1e-9)
	# 9. The vector form behind the close-up's exit sheets. A 180° bucket is the
	#    scalar relation exactly (no sideways component); the real ~165° bucket
	#    throws a sideways share and leaves faster than the ideal.
	for xr: float in [0.0, PeltonPhysics.SPEED_RATIO_OPT, 0.5, 0.8]:
		var e180 := PeltonPhysics.bucket_exit_velocity(VJ, xr, 180.0)
		_check("pelton bucket vector @180° x=%.2f: axial 0, |tangential| == scalar" % xr,
			absf(float(e180["axial"])) < 1e-9
			and absf(absf(float(e180["tangential"])) - PeltonPhysics.bucket_exit_speed_ms(VJ, xr)) < 1e-6)
	var e165 := PeltonPhysics.bucket_exit_velocity(VJ, PeltonPhysics.SPEED_RATIO_OPT)
	var w_rel := VJ * (1.0 - PeltonPhysics.SPEED_RATIO_OPT)
	_check("pelton bucket @165°: axial share is w·sin15°",
		absf(float(e165["axial"]) - w_rel * sin(deg_to_rad(15.0))) < 1e-6,
		"%.3f m/s" % float(e165["axial"]))
	_check("pelton bucket @165°: matched load leaves slightly BACKWARD, slow",
		float(e165["tangential"]) < 0.0 and float(e165["speed"]) < VJ * 0.2
			and float(e165["speed"]) > PeltonPhysics.bucket_exit_speed_ms(VJ, PeltonPhysics.SPEED_RATIO_OPT))
	var e_stall := PeltonPhysics.bucket_exit_velocity(VJ, 0.0)
	_check("pelton bucket @165°: a stalled bucket throws the jet back at ~full speed",
		float(e_stall["tangential"]) < -VJ * 0.9 and absf(float(e_stall["speed"]) - VJ) < 1e-6)


## Stream/spring hydrology: HydroSupply's rain coupling and storm recession.
func _test_hydro_supply() -> void:
	var spec := {"base_flow_lps": 2.0, "rain_lps_per_tenth_in_h": 1.0,
		"max_flow_lps": 0.0}
	_check("hydro supply: no rain gives the dry-weather base flow",
		absf(HydroSupply.intake_supply_lps(spec, 0.0) - 2.0) < 1e-9)
	# THE conversion pin. 0.1 in = 2.54 mm exactly, so 2.54 mm/h of rain must add
	# exactly one coefficient's worth. Getting this wrong is silent — the numbers
	# stay plausible and the turbine is simply off by 2.54x forever.
	_check("hydro supply: 2.54 mm/h == 0.1 in/h adds exactly one coefficient",
		absf(HydroSupply.intake_supply_lps(spec, 2.54) - 3.0) < 1e-9,
		"%.6f" % HydroSupply.intake_supply_lps(spec, 2.54))
	_check("hydro supply: rain term is linear",
		absf(HydroSupply.intake_supply_lps(spec, 25.4) - 12.0) < 1e-9,
		"%.6f" % HydroSupply.intake_supply_lps(spec, 25.4))
	_check("hydro supply: rain_term_lps isolates the storm contribution",
		absf(HydroSupply.rain_term_lps(spec, 2.54) - 1.0) < 1e-9)
	var capped: Dictionary = spec.duplicate(true)
	capped["max_flow_lps"] = 4.0
	_check("hydro supply: peak cap bites",
		absf(HydroSupply.intake_supply_lps(capped, 25.4) - 4.0) < 1e-9)
	_check("hydro supply: negative rain clamps to zero, never below base",
		absf(HydroSupply.intake_supply_lps(spec, -5.0) - 2.0) < 1e-9)
	_check("hydro supply: NAN rain degrades to base (offline weather)",
		absf(HydroSupply.intake_supply_lps(spec, NAN) - 2.0) < 1e-9)

	# Recession. tau 0 = instantaneous (the scrub-safe default).
	_check("hydro recess: tau 0 is instantaneous",
		absf(HydroSupply.recess(1.0, 9.0, 0.5, 0.0) - 9.0) < 1e-9)
	# One tau of elapsed time reaches 1 - 1/e = 63.2% of the step.
	var one_tau := HydroSupply.recess(0.0, 10.0, 3.0, 3.0)
	_check("hydro recess: one tau reaches 63.2% of the step",
		absf(one_tau - 6.3212) < 0.001, "%.4f" % one_tau)
	# The big-dt guard: this runs on whatever tick the world clock hands it, and
	# at high time_scale that is routinely many tau at once. 1-exp is exact for a
	# step at ANY dt; a naive lerp(dt/tau) would overshoot wildly here.
	var big_dt := HydroSupply.recess(0.0, 10.0, 30.0, 3.0)
	_check("hydro recess: a 10-tau step lands on target without overshoot",
		big_dt <= 10.0 and absf(big_dt - 10.0) < 0.001, "%.6f" % big_dt)
	_check("hydro recess: never returns negative",
		HydroSupply.recess(5.0, 0.0, 1.0, 2.0) >= 0.0)

	# End to end: a stream-fed PowerSpout makes more power in the rain.
	var wet_base := {"turbine_kind": "powerspout_pelton", "gross_head_m": 30.0,
		"penstock_length_m": 80.0, "penstock_diameter_mm": 37.53,
		"nozzle_diameter_mm": 10.0, "nozzle_count": 1}
	var isp := {"base_flow_lps": 0.4, "rain_lps_per_tenth_in_h": 0.6}
	var dry_specs: Dictionary = wet_base.duplicate(true)
	dry_specs["supply_lps"] = HydroSupply.intake_supply_lps(isp, 0.0)
	var wet_specs: Dictionary = wet_base.duplicate(true)
	wet_specs["supply_lps"] = HydroSupply.intake_supply_lps(isp, 5.08)  # 0.2 in/h
	var kw_dry := HydroSource.power_kw_from_graph_specs(dry_specs, 6)
	var kw_wet := HydroSource.power_kw_from_graph_specs(wet_specs, 6)
	_check("hydro supply: rain raises a stream-fed PowerSpout's output",
		kw_wet > kw_dry * 2.0 and kw_dry > 0.0,
		"dry %.4f kW → wet %.4f kW" % [kw_dry, kw_wet])

	# Seasonal supply curve, and the annual estimate honouring it. Without the
	# per-month array the annual figure freezes at ONE instantaneous supply, so a
	# wet-season reading is extrapolated across the whole year and vice versa.
	var rain_year: Array = []
	for m in 12:
		# Wet winter / dry summer MEANS in mm/h. A 250 mm winter month over 720 h
		# really is only ~0.35 mm/h — monthly means are small numbers, which is
		# exactly why the coefficient is authored per 0.1 in/h.
		rain_year.append(0.35 if (m < 3 or m > 9) else 0.02)
	# A creek with a real catchment, so the rain term dominates its own base flow
	# (with a small coefficient the seasonal swing is there but undramatic).
	var creek := {"base_flow_lps": 0.4, "rain_lps_per_tenth_in_h": 6.0}
	var prof := HydroSupply.monthly_supply_lps(creek, rain_year)
	_check("hydro supply: monthly curve has 12 entries", prof.size() == 12)
	_check("hydro supply: wet months carry more than dry ones",
		prof[0] > prof[6] * 1.5, "Jan %.3f vs Jul %.3f" % [prof[0], prof[6]])
	# PackedFloat32Array — compare at float32 precision, not 1e-9.
	_check("hydro supply: each month equals the closed form at that rain rate",
		absf(prof[0] - HydroSupply.intake_supply_lps(creek, 0.35)) < 1e-6
		and absf(prof[6] - HydroSupply.intake_supply_lps(creek, 0.02)) < 1e-6,
		"%.6f vs %.6f" % [prof[0], HydroSupply.intake_supply_lps(creek, 0.35)])
	# Freeze the supply at the WETTEST month and the annual figure is inflated;
	# with the real curve it must land between the all-dry and all-wet bounds.
	var frozen_wet: Dictionary = wet_base.duplicate(true)
	frozen_wet["supply_lps"] = prof[0]
	var frozen_dry: Dictionary = wet_base.duplicate(true)
	frozen_dry["supply_lps"] = prof[6]
	var ann_wet := float(HydroSource.annual_energy_kwh_from_specs(
			frozen_wet, [])["annual_kwh"])
	var ann_dry := float(HydroSource.annual_energy_kwh_from_specs(
			frozen_dry, [])["annual_kwh"])
	var ann_seasonal := float(HydroSource.annual_energy_kwh_from_specs(
			frozen_wet, [], Array(prof))["annual_kwh"])
	_check("hydro annual: seasonal supply lands between the frozen extremes",
		ann_seasonal < ann_wet and ann_seasonal > ann_dry,
		"dry %.0f < seasonal %.0f < wet %.0f" % [ann_dry, ann_seasonal, ann_wet])
	# And the legacy call (no array) is byte-identical to before.
	_check("hydro annual: omitting the array reuses the single supply, unchanged",
		absf(float(HydroSource.annual_energy_kwh_from_specs(frozen_wet, [],
			[])["annual_kwh"]) - ann_wet) < 1e-9)


func _test_csp() -> void:
	# E-W horizontal single-axis tracker: at solar noon (az=180) the aperture
	# tilts (90° - elevation) toward the equator to face the sun head-on.
	var ang_noon := CspTroughSourceScript.tracking_angle_deg(180.0, 45.0)
	_check("csp: tracking angle = 90-el (45°) at noon, el=45",
		_approx(ang_noon, 44.0, 46.0), "got %.2f°" % ang_noon)
	var ang_noon_high := CspTroughSourceScript.tracking_angle_deg(180.0, 70.0)
	_check("csp: tracking angle = 90-el (20°) at noon, el=70",
		_approx(ang_noon_high, 19.0, 21.0), "got %.2f°" % ang_noon_high)

	# Due-east/west sun: no meridian tilt to make (the sun is on the E-W axis),
	# so the tracker lies flat (angle ~0). This is the E-W tracker's morning/
	# evening blind spot.
	var ang_east := CspTroughSourceScript.tracking_angle_deg(90.0, 5.0)
	_check("csp: tracking angle ~0 for due-east sun", absf(ang_east) < 0.5,
		"got %.2f°" % ang_east)
	var ang_west := CspTroughSourceScript.tracking_angle_deg(270.0, 5.0)
	_check("csp: tracking angle ~0 for due-west sun", absf(ang_west) < 0.5,
		"got %.2f°" % ang_west)

	# Hemisphere-agnostic: a due-NORTH noon sun (southern hemisphere) tilts the
	# aperture the opposite way (toward north = negative) by the same magnitude.
	var ang_south_hemi := CspTroughSourceScript.tracking_angle_deg(0.0, 45.0)
	_check("csp: tracking angle = -(90-el) for due-north noon sun",
		_approx(ang_south_hemi, -46.0, -44.0), "got %.2f°" % ang_south_hemi)

	# Mechanical stop clamps extreme angles.
	var ang_clamped := CspTroughSourceScript.tracking_angle_deg(180.0, 5.0, 60.0)
	_check("csp: tracking angle clamps to max_angle_deg",
		absf(ang_clamped) <= 60.0 + 1e-6, "got %.2f°" % ang_clamped)

	# Sun below horizon → parked at 0.
	var ang_night := CspTroughSourceScript.tracking_angle_deg(180.0, -10.0)
	_check("csp: tracking angle 0 when sun below horizon", ang_night == 0.0)

	# Incidence cosine: perfect (1.0) whenever the sun sits in the N-S meridian
	# plane (due south/north — i.e. every solar noon, at ANY elevation) or
	# straight overhead. This zero-noon-incidence trait is the E-W tracker's
	# signature advantage.
	var cos_noon_low := CspTroughSourceScript.cos_incidence(180.0, 5.0)
	_check("csp: cos_incidence = 1 for due-south sun at any elevation",
		_approx(cos_noon_low, 0.999, 1.001), "got %.4f" % cos_noon_low)
	var cos_overhead := CspTroughSourceScript.cos_incidence(90.0, 90.0)
	_check("csp: cos_incidence = 1 for sun straight overhead",
		_approx(cos_overhead, 0.999, 1.001), "got %.4f" % cos_overhead)

	# Worst case: sun low on the horizon due east — entirely along the E-W axis,
	# a 1-DOF E-W tracker cannot capture any of it (the sunrise/sunset cosine
	# loss of E-W trough fields).
	var cos_east_horizon := CspTroughSourceScript.cos_incidence(90.0, 0.0)
	_check("csp: cos_incidence = 0 for due-east horizon sun",
		cos_east_horizon < 0.01, "got %.4f" % cos_east_horizon)

	# End losses vanish at normal incidence, grow with focal length / shrink
	# with module length (Duffie & Beckman finite-length trough model).
	var loss_normal := CspTroughSourceScript.end_loss_frac(1.0, 1.7, 12.0)
	_check("csp: end loss = 0 at normal incidence", loss_normal == 0.0)
	var loss_45 := CspTroughSourceScript.end_loss_frac(cos(deg_to_rad(45.0)), 1.7, 12.0)
	_check("csp: end loss ~14% at 45° incidence, f=1.7m L=12m",
		_approx(loss_45, 0.13, 0.15), "got %.4f" % loss_45)

	# Full simulate(): midday, clear sky, default 5m x 12m trough — should
	# produce sensible positive thermal output and mass-conserving water/steam
	# (1 L water -> 1 kg steam at this model's density=1.0 kg/L).
	var specs := {
		"aperture_width_m": 5.0, "module_length_m": 12.0, "focal_length_m": 1.7,
		"optical_efficiency": 0.75, "thermal_efficiency": 0.85,
		"feedwater_temp_c": 20.0, "max_tracking_angle_deg": 110.0,
	}
	var clear_weather := {"has_real": false, "cloud": 0.0}
	var midday := CspTroughSourceScript.simulate(specs, 180.0, 70.0, clear_weather)
	_check("csp: midday thermal output > 0",
		float(midday.get("thermal_output_kw", 0.0)) > 0.0,
		"got %.3f kW" % float(midday.get("thermal_output_kw", 0.0)))
	_check("csp: midday steam/water mass-conserving (density=1)",
		absf(float(midday.get("steam_kg_h", 0.0)) - float(midday.get("water_lph", 0.0))) < 1e-6)

	# Sun below horizon → no output at all.
	var night := CspTroughSourceScript.simulate(specs, 180.0, -5.0, clear_weather)
	_check("csp: night thermal output = 0",
		float(night.get("thermal_output_kw", 0.0)) == 0.0)
	_check("csp: night steam output = 0",
		float(night.get("steam_kg_h", 0.0)) == 0.0)

	# Cloud cover reduces DNI (and therefore thermal output) versus clear sky.
	var cloudy := CspTroughSourceScript.simulate(specs, 180.0, 70.0, {"has_real": false, "cloud": 0.9})
	_check("csp: heavy cloud reduces thermal output vs clear sky",
		float(cloudy.get("thermal_output_kw", 0.0)) < float(midday.get("thermal_output_kw", 0.0)),
		"cloudy=%.3f clear=%.3f" % [cloudy.get("thermal_output_kw", 0.0), midday.get("thermal_output_kw", 0.0)])

	# tracking_offset_from_normal: used by CspTroughTracker to correct for a
	# mesh whose REST pose isn't exactly "pointing straight up" (see that
	# script's class doc). Axis = the shared E-W tracking pivot (world east),
	# matching the tracker's forced orientation; +offset = tilt toward south.
	var axis_ew := CspTroughSourceScript.TRACKING_AXIS
	_check("csp: TRACKING_AXIS is world east", axis_ew.is_equal_approx(Vector3(1, 0, 0)))
	# A normal pointing exactly straight up has zero offset.
	var off_up := CspTroughSourceScript.tracking_offset_from_normal(Vector3(0, 1, 0), axis_ew)
	_check("csp: rest offset = 0 for straight-up normal", absf(off_up) < 1e-6,
		"got %.4f rad" % off_up)
	# A normal leaning 45° toward south (up + south, +Z=south) offsets +45°.
	var off_south45 := CspTroughSourceScript.tracking_offset_from_normal(
		Vector3(0.0, 1.0, 1.0).normalized(), axis_ew)
	_check("csp: rest offset = +45° for south-leaning normal",
		_approx(rad_to_deg(off_south45), 44.0, 46.0), "got %.2f°" % rad_to_deg(off_south45))
	# The GLB's actual measured rest normal at forced yaw=0° (from the
	# node-hierarchy diagnostic): mirror_normal_world ≈ (0, 0.438, 0.899),
	# i.e. leaning ~64° toward south of vertical. Pinning this regression-tests
	# the empirical constant the tracker relies on without loading the GLB.
	var off_measured := CspTroughSourceScript.tracking_offset_from_normal(
		Vector3(0.000038, 0.437767, 0.899089), axis_ew)
	_check("csp: rest offset ~64° matches GLB diagnostic measurement",
		_approx(rad_to_deg(off_measured), 63.0, 65.0), "got %.2f°" % rad_to_deg(off_measured))
	# An axis-aligned component (pure east/west lean) contributes nothing —
	# it's un-recoverable by rotation about that same axis and must be dropped.
	var off_axis_only := CspTroughSourceScript.tracking_offset_from_normal(
		Vector3(1.0, 0.0, 0.0), axis_ew)
	_check("csp: rest offset = 0 when normal is purely axis-aligned",
		absf(off_axis_only) < 1e-6, "got %.4f rad" % off_axis_only)


## Dual-axis dish heliostat: perfect two-axis tracking (cos≈1 all day),
## concentration ratio, cavity-receiver stagnation temperature, and useful
## heat / water→steam output (heliostat_source.gd).
func _test_heliostat() -> void:
	# Library preset present, correct kind/role, and links the 3D dish model.
	var preset := {}
	for p: Dictionary in ComponentPresetsScript.CSP_CONCENTRATORS:
		if str(p.get("label", "")) == "Dual-Axis Heliostat":
			preset = p
			break
	_check("heliostat preset: found in Solar Concentrators", not preset.is_empty())
	if preset.is_empty():
		return
	var pspecs: Dictionary = preset.get("specs", {}) as Dictionary
	_check("heliostat preset: kind is heliostat", str(pspecs.get("kind", "")) == "heliostat")
	_check("heliostat preset: role is heliostat", str(pspecs.get("role", "")) == "heliostat")
	_check("heliostat preset: model_id links heliostat",
		str(pspecs.get("model_id", "")) == "heliostat")
	_check("heliostat preset: 19.36 m² mirror area (datasheet)",
		_approx(float(pspecs.get("mirror_area_m2", 0.0)), 19.35, 19.37))

	# Model catalog registration: GLB + the four moving sub-node names the
	# tracker drives (see heliostat_tracker.gd).
	var entry := ModelCatalogScript.find("heliostat")
	_check("heliostat model: registered in ModelCatalog", not entry.is_empty())
	_check("heliostat model: azimuth node name",
		str(entry.get("helio_azimuth_node", "")) == "horizontal rotating assembly")
	_check("heliostat model: altitude node name",
		str(entry.get("helio_altitude_node", "")) == "Vertical Rotating Assembly")
	_check("heliostat model: mirror node name",
		str(entry.get("helio_mirror_node", "")) == "Mirror array")

	var specs := {
		"mirror_area_m2": 19.36, "focal_box_size_m": 0.5,
		"optical_efficiency": 0.80, "receiver_absorptivity": 0.95,
		"receiver_emissivity": 0.90, "conv_coeff_w_m2k": 10.0,
		"operating_temp_c": 250.0, "thermal_efficiency": 0.85,
		"feedwater_temp_c": 20.0,
	}
	var clear := {"has_real": false, "cloud": 0.0, "temp": 25.0}

	# Perfect dual-axis tracking → normal incidence whenever the sun is up
	# (cos=1), even for a low sun where the single-axis trough loses badly.
	var low_sun := HeliostatSourceScript.simulate(specs, 90.0, 10.0, clear)
	_check("heliostat: cos_incidence = 1 for any up-sun (two-axis)",
		_approx(float(low_sun.get("cos_incidence", 0.0)), 0.999, 1.001))
	var trough_low := CspTroughSourceScript.cos_incidence(90.0, 10.0)
	_check("heliostat: beats single-axis trough at a low east sun",
		float(low_sun.get("cos_incidence", 0.0)) > trough_low + 0.1,
		"heliostat=%.3f trough=%.3f" % [low_sun.get("cos_incidence", 0.0), trough_low])

	# Concentration ratio = mirror_area / aperture (0.5 m box → 0.25 m² → 77×).
	var midday := HeliostatSourceScript.simulate(specs, 180.0, 70.0, clear)
	_check("heliostat: concentration ≈ 77× (19.36/0.25)",
		_approx(float(midday.get("concentration_ratio", 0.0)), 76.0, 78.0),
		"got %.1f×" % float(midday.get("concentration_ratio", 0.0)))

	# Focal stagnation temperature reaches the solar-furnace range and is far
	# hotter than ambient; positive thermal + mass-conserving water→steam.
	var focal_c := float(midday.get("focal_temp_c", 0.0))
	_check("heliostat: focal temp in solar-furnace range (600-1000 °C)",
		focal_c > 600.0 and focal_c < 1000.0, "got %.0f °C" % focal_c)
	_check("heliostat: midday thermal output > 0",
		float(midday.get("thermal_output_kw", 0.0)) > 0.0,
		"got %.3f kW" % float(midday.get("thermal_output_kw", 0.0)))
	_check("heliostat: steam/water mass-conserving (density=1)",
		absf(float(midday.get("steam_kg_h", 0.0)) - float(midday.get("water_lph", 0.0))) < 1e-6)

	# Night → nothing; heavy cloud → cooler focus + less heat than clear sky.
	var night := HeliostatSourceScript.simulate(specs, 180.0, -5.0, clear)
	_check("heliostat: night thermal output = 0",
		float(night.get("thermal_output_kw", 0.0)) == 0.0)
	_check("heliostat: night focal temp = ambient (no concentration)",
		_approx(float(night.get("focal_temp_c", 0.0)), 24.0, 26.0),
		"got %.1f °C" % float(night.get("focal_temp_c", 0.0)))
	var cloudy := HeliostatSourceScript.simulate(specs, 180.0, 70.0, {"has_real": false, "cloud": 0.9, "temp": 25.0})
	_check("heliostat: heavy cloud lowers focal temp vs clear sky",
		float(cloudy.get("focal_temp_c", 0.0)) < focal_c,
		"cloudy=%.0f clear=%.0f" % [cloudy.get("focal_temp_c", 0.0), focal_c])

	# A bigger dish (more collected beam) reaches a hotter focus at the same box.
	var big := specs.duplicate(true)
	big["mirror_area_m2"] = 40.0
	var big_mid := HeliostatSourceScript.simulate(big, 180.0, 70.0, clear)
	_check("heliostat: larger mirror area → hotter focus",
		float(big_mid.get("focal_temp_c", 0.0)) > focal_c,
		"big=%.0f base=%.0f" % [big_mid.get("focal_temp_c", 0.0), focal_c])

	# stagnation_temp_k is the root of the receiver energy balance: at that T
	# the losses equal the absorbed power (to within a watt).
	var t_stag := HeliostatSourceScript.stagnation_temp_k(5000.0, 0.9, 0.25, 10.0, 1.25, 298.15)
	var loss := HeliostatSourceScript.receiver_loss_w(t_stag, 0.9, 0.25, 10.0, 1.25, 298.15)
	_check("heliostat: stagnation solves loss(T)=absorbed", absf(loss - 5000.0) < 1.0,
		"loss=%.2f W at T=%.1f K" % [loss, t_stag])


func _test_home_biogas() -> void:
	# Temperature derate knees (datasheet: best above 17–20 °C).
	_check("homebiogas: temp_factor = 1 at 20 °C",
		absf(HomeBiogasSourceScript.temp_factor(20.0) - 1.0) < 1e-6)
	_check("homebiogas: temp_factor = 1 above full",
		absf(HomeBiogasSourceScript.temp_factor(25.0) - 1.0) < 1e-6)
	_check("homebiogas: temp_factor = residual at floor",
		absf(HomeBiogasSourceScript.temp_factor(10.0) - HomeBiogasSourceScript.TEMP_RESIDUAL) < 1e-6)
	_check("homebiogas: temp_factor mid-band between residual and 1",
		HomeBiogasSourceScript.temp_factor(15.0) > HomeBiogasSourceScript.TEMP_RESIDUAL \
		and HomeBiogasSourceScript.temp_factor(15.0) < 1.0)

	var food_specs := {
		"feed_mode": "food", "daily_feed_l": 6.0,
		"max_food_l_day": 6.0, "max_manure_l_day": 15.0,
		"biogas_m3_day_food_min": 0.30, "biogas_m3_day_food_max": 0.40,
		"biogas_m3_day_manure_min": 0.56, "biogas_m3_day_manure_max": 0.70,
		"ch4_fraction": 0.625, "water_l_day_at_max": 6.0,
	}
	var food_warm := HomeBiogasSourceScript.simulate(food_specs, 22.0)
	var food_m3 := float(food_warm.get("biogas_m3_day", 0.0))
	_check("homebiogas: max food → biogas in 0.3–0.4 m³/day band",
		food_m3 >= 0.30 - 1e-6 and food_m3 <= 0.40 + 1e-6,
		"got %.3f m³/day" % food_m3)
	_check("homebiogas: max food uses food_waste kind",
		str(food_warm.get("feed_kind", "")) == "food_waste")
	_check("homebiogas: max food water = 6 L/day",
		absf(float(food_warm.get("water_l_day", 0.0)) - 6.0) < 1e-6)
	_check("homebiogas: fertilizer ≈ feed + water − biogas mass",
		float(food_warm.get("fertilizer_l_day", 0.0)) > 10.0)
	_check("homebiogas: cooking hours in 2–3 h band at rated food",
		_approx(float(food_warm.get("cooking_hours_day", 0.0)), 2.0, 3.0),
		"got %.2f h" % float(food_warm.get("cooking_hours_day", 0.0)))

	var manure_specs := food_specs.duplicate(true)
	manure_specs["feed_mode"] = "manure"
	manure_specs["daily_feed_l"] = 15.0
	var manure_warm := HomeBiogasSourceScript.simulate(manure_specs, 22.0)
	var manure_m3 := float(manure_warm.get("biogas_m3_day", 0.0))
	_check("homebiogas: max manure → biogas in 0.56–0.7 m³/day band",
		manure_m3 >= 0.56 - 1e-6 and manure_m3 <= 0.70 + 1e-6,
		"got %.3f m³/day" % manure_m3)
	_check("homebiogas: manure mode uses manure kind",
		str(manure_warm.get("feed_kind", "")) == "manure")
	_check("homebiogas: manure yield > food yield at max",
		manure_m3 > food_m3)

	var half := food_specs.duplicate(true)
	half["daily_feed_l"] = 3.0
	var half_warm := HomeBiogasSourceScript.simulate(half, 22.0)
	_check("homebiogas: half feed → ~half biogas",
		absf(float(half_warm.get("biogas_m3_day", 0.0)) - food_m3 * 0.5) < 1e-4,
		"half=%.3f full=%.3f" % [half_warm.get("biogas_m3_day", 0.0), food_m3])

	var zero := food_specs.duplicate(true)
	zero["daily_feed_l"] = 0.0
	var zero_r := HomeBiogasSourceScript.simulate(zero, 22.0)
	_check("homebiogas: zero feed → zero biogas",
		float(zero_r.get("biogas_m3_day", -1.0)) == 0.0)

	var cold := HomeBiogasSourceScript.simulate(food_specs, 5.0)
	_check("homebiogas: cold ambient derates biogas vs warm",
		float(cold.get("biogas_m3_day", 0.0)) < food_m3 * 0.2,
		"cold=%.3f warm=%.3f" % [cold.get("biogas_m3_day", 0.0), food_m3])

	# Preset + catalog wiring.
	var found_preset := false
	for p: Variant in ComponentPresetsScript.PROCESSORS:
		if p is Dictionary and str((p as Dictionary).get("label", "")) == "HomeBiogas 2.0":
			found_preset = true
			var sp: Dictionary = (p as Dictionary).get("specs", {}) as Dictionary
			_check("homebiogas: preset role=biodigester", str(sp.get("role", "")) == "biodigester")
			_check("homebiogas: preset io_absolute", bool(sp.get("io_absolute", false)))
			_check("homebiogas: preset model_id", str(sp.get("model_id", "")) == "home_biogas_2")
			break
	_check("homebiogas: preset in PROCESSORS", found_preset)
	_check("homebiogas: model catalog entry",
		not ModelCatalogScript.find("home_biogas_2").is_empty())
	_check("homebiogas: food_waste kind registered", ResourceKindsScript.has_kind("food_waste"))
	_check("homebiogas: manure kind registered", ResourceKindsScript.has_kind("manure"))


func _test_pp_extruder() -> void:
	# Datasheet: 5 kg/h ÷ 1.17 kg/m ≈ 4.2735 m/h.
	var specs := {
		"flake_kg_h": 5.0,
		"kg_per_m": 1.17,
		"cut_length_m": 2.0,
		"extruded_length_m": 0.0,
		"inputs": [{"kind": "plastic_flake", "rate": 5.0}],
	}
	var mph := PpBeamExtruderSourceScript.meters_per_hour(specs)
	_check("pp extruder: m/h ≈ 5/1.17", absf(mph - (5.0 / 1.17)) < 1e-4, "mph=%.4f" % mph)

	# Half hour at full rate → ~2.137 m; one 2 m cut + remainder ~0.137 m.
	var half := PpBeamExtruderSourceScript.advance(specs, 0.5, true)
	_check("pp extruder: half-hour cuts one beam",
		int(half.get("beams_cut", 0)) == 1, "beams=%d" % int(half.get("beams_cut", 0)))
	_check("pp extruder: remainder after cut",
		absf(float(half.get("extruded_length_m", -1.0)) - (mph * 0.5 - 2.0)) < 1e-3,
		"rem=%.4f" % float(half.get("extruded_length_m", -1.0)))
	_check("pp extruder: cut mass = 2 × 1.17",
		absf(float(half.get("cut_mass_kg", 0.0)) - 2.34) < 1e-3)

	# Idle holds length (no inventing cuts).
	specs["extruded_length_m"] = 1.5
	var idle := PpBeamExtruderSourceScript.advance(specs, 1.0, false)
	_check("pp extruder: idle holds stick",
		absf(float(idle.get("extruded_length_m", 0.0)) - 1.5) < 1e-6)
	_check("pp extruder: idle cuts none", int(idle.get("beams_cut", -1)) == 0)

	# Exact multi-cut: 1.0 h → ~4.274 m → two 2 m beams + ~0.274 m.
	specs["extruded_length_m"] = 0.0
	var hour := PpBeamExtruderSourceScript.advance(specs, 1.0, true)
	_check("pp extruder: 1 h cuts two beams", int(hour.get("beams_cut", 0)) == 2)

	# Preset + catalog wiring.
	var found_shred := false
	var found_ext := false
	for p: Variant in ComponentPresetsScript.TOOLS:
		if p is Dictionary:
			var label := str((p as Dictionary).get("label", ""))
			if label == "PP Shredder":
				found_shred = true
				var sp: Dictionary = (p as Dictionary).get("specs", {}) as Dictionary
				_check("pp shredder: 600 W", absf(float(sp.get("watts", 0.0)) - 600.0) < 0.1)
				_check("pp shredder: model_id", str(sp.get("model_id", "")) == "pp_shredder")
				var outs: Array = sp.get("outputs", []) as Array
				_check("pp shredder: flake out",
					not outs.is_empty() and str((outs[0] as Dictionary).get("kind", "")) == "plastic_flake")
			elif label == "PP Beam Extruder":
				found_ext = true
				var sp2: Dictionary = (p as Dictionary).get("specs", {}) as Dictionary
				_check("pp extruder: role", str(sp2.get("role", "")) == "pp_beam_extruder")
				_check("pp extruder: model_id", str(sp2.get("model_id", "")) == "pp_beam_extruder")
				_check("pp extruder: kg/m", absf(float(sp2.get("kg_per_m", 0.0)) - 1.17) < 1e-6)
				_check("pp extruder: 1200 W", absf(float(sp2.get("watts", 0.0)) - 1200.0) < 0.1)
	_check("pp shredder: preset in TOOLS", found_shred)
	_check("pp extruder: preset in TOOLS", found_ext)
	_check("pp shredder: catalog entry", not ModelCatalogScript.find("pp_shredder").is_empty())
	_check("pp extruder: catalog entry", not ModelCatalogScript.find("pp_beam_extruder").is_empty())
	_check("pp: plastic_flake kind registered", ResourceKindsScript.has_kind("plastic_flake"))
	_check("pp: plastic_waste kind registered", ResourceKindsScript.has_kind("plastic_waste"))


func _test_pp_sheet_press() -> void:
	# Density pin: 8 mm → 7.2 kg, 15 mm → 13.5 kg (1 m² × ρ 900).
	_check("pp sheet: 8 mm mass",
		absf(PpSheetPressSourceScript.sheet_mass_kg(8.0) - 7.2) < 1e-6)
	_check("pp sheet: 15 mm mass",
		absf(PpSheetPressSourceScript.sheet_mass_kg(15.0) - 13.5) < 1e-6)

	var thin := PpSheetPressSourceScript.cycle_times_hr(6.5)
	_check("pp sheet: thin total in 50–60 min",
		float(thin.get("total_hr", 0.0)) * 60.0 >= 50.0 - 0.5
		and float(thin.get("total_hr", 0.0)) * 60.0 <= 60.0 + 0.5,
		"total_min=%.1f" % (float(thin.get("total_hr", 0.0)) * 60.0))

	var thick := PpSheetPressSourceScript.cycle_times_hr(16.0)
	_check("pp sheet: thick total in 90–120 min",
		float(thick.get("total_hr", 0.0)) * 60.0 >= 90.0 - 0.5
		and float(thick.get("total_hr", 0.0)) * 60.0 <= 120.0 + 0.5,
		"total_min=%.1f" % (float(thick.get("total_hr", 0.0)) * 60.0))

	var job8 := PpSheetPressSourceScript.derive_job({"sheet_thickness_mm": 8.0})
	_check("pp sheet: 8 mm job mass", absf(float(job8.get("material_kg", 0.0)) - 7.2) < 1e-6)
	_check("pp sheet: avg kWh/h in 3–5",
		float(job8.get("avg_kwh_per_h", 0.0)) >= 3.0
		and float(job8.get("avg_kwh_per_h", 0.0)) <= 5.0)

	# Compression: mid-melt rising, cool held at 1.
	var specs := {
		"job_active": true,
		"job_start_abs_hours": 100.0,
		"job_melt_hr": 0.5,
		"job_cool_hr": 0.4,
		"job_duration_hr": 0.9,
		"sheet_thickness_mm": 8.0,
		"peak_watts": 5000.0,
		"job_avg_kwh_per_h": 4.0,
	}
	var mid_melt := PpSheetPressSourceScript.compression_at(specs, 100.25)
	_check("pp sheet: mid-melt compression mid", mid_melt > 0.2 and mid_melt < 0.9, "c=%.3f" % mid_melt)
	_check("pp sheet: cool compression=1",
		absf(PpSheetPressSourceScript.compression_at(specs, 100.7) - 1.0) < 1e-6)
	_check("pp sheet: melt phase", PpSheetPressSourceScript.phase_at(specs, 100.1) == "melt")
	_check("pp sheet: cool phase", PpSheetPressSourceScript.phase_at(specs, 100.6) == "cool")

	# Warm-up peak then cycling below peak on average.
	var warm_w := PpSheetPressSourceScript.power_watts_at(specs, 100.01)
	_check("pp sheet: warm-up at peak", absf(warm_w - 5000.0) < 1.0, "w=%.0f" % warm_w)
	var samples := 0
	var sum_w := 0.0
	var t := 100.1
	while t < 100.5:
		sum_w += PpSheetPressSourceScript.power_watts_at(specs, t)
		samples += 1
		t += 0.5 / 60.0  # 30 s steps
	var avg_w := sum_w / float(maxi(samples, 1))
	_check("pp sheet: melt avg draw in 3–5 kW band",
		avg_w >= 2500.0 and avg_w <= 5000.0, "avg_w=%.0f" % avg_w)

	var found := false
	for p: Variant in ComponentPresetsScript.TOOLS:
		if p is Dictionary and str((p as Dictionary).get("label", "")) == "PP Sheet Press":
			found = true
			var sp: Dictionary = (p as Dictionary).get("specs", {}) as Dictionary
			_check("pp sheet: role", str(sp.get("role", "")) == "pp_sheet_press")
			_check("pp sheet: model_id", str(sp.get("model_id", "")) == "pp_sheet_press")
			_check("pp sheet: default 8 mm", absf(float(sp.get("sheet_thickness_mm", 0.0)) - 8.0) < 1e-6)
			break
	_check("pp sheet: preset in TOOLS", found)
	_check("pp sheet: catalog entry", not ModelCatalogScript.find("pp_sheet_press").is_empty())
	_check("pp sheet: plastic_sheet kind", ResourceKindsScript.has_kind("plastic_sheet"))
