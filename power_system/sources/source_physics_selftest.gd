extends SceneTree

## Headless physics self-test for the EnergySource family.
## Run with:
##   godot --headless --path . --script power_system/sources/source_physics_selftest.gd
## Exits 0 when all assertions pass, 1 otherwise.

const ResourceKindsScript := preload("res://system_graph/data/resource_kinds.gd")

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
