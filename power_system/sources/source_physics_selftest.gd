extends SceneTree

## Headless physics self-test for the EnergySource family.
## Run with:
##   godot --headless --path . --script power_system/sources/source_physics_selftest.gd
## Exits 0 when all assertions pass, 1 otherwise.

const ResourceKindsScript := preload("res://system_graph/data/resource_kinds.gd")
const ResourceEdgeVisScript := preload("res://system_graph/data/resource_edge_vis.gd")
const CspTroughSourceScript := preload("res://power_system/sources/csp_trough_source.gd")

var _failures: int = 0
var _checks: int = 0


func _initialize() -> void:
	_test_wind()
	_test_hydro()
	_test_defaults()
	_test_graph_adapters()
	_test_weather_service()
	_test_solar_physics()
	_test_timecode()
	_test_timeline_view()
	_test_comparison()
	_test_resource_flow()
	_test_resource_edges()
	_test_season()
	_test_solar_eclipse()
	_test_csp()
	if _failures == 0:
		print("SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


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
	clk.day_time = 13.35  # near maximum totality (~13:21-13:40 CDT window)
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
