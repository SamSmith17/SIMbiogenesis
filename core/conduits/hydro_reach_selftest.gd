extends SceneTree

## HydroReach spike selftest (offline, deterministic). Proves the unified reach:
##   1. Parity — evaluate() reproduces SiphonHydraulics.simulate at a fixed level.
##   2. Prime/break hysteresis over a stepped fill/drain cycle.
##   3. Mass conservation — stock + outlet + overflow == initial + inflow.
##   4. Drain floors at the air-break level (siphon sucks air, pond doesn't empty).
##   5. Overflow accounting at the rim.
## Run: Godot.exe.exe --headless --path . --script core/conduits/hydro_reach_selftest.gd

var _checks := 0
var _fails := 0


func _init() -> void:
	print("=== HydroReach selftest ===")
	_test_parity()
	_test_prime_break_cycle()
	_test_mass_conservation()
	_test_break_floor()
	_test_drainable_lph()
	_test_overflow()
	_test_legacy_parity()
	_test_penstock_operating_point()
	_test_penstock_capacity_solve()
	_test_penstock_nameplate()
	_test_penstock_drawdown()
	_test_nozzle_model()
	_test_stream_source()
	print("--- %d checks, %d failures ---" % [_checks, _fails])
	quit(1 if _fails > 0 else 0)


func _ok(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("  FAIL: %s" % label)


func _approx(a: float, b: float, eps: float, label: String) -> void:
	_checks += 1
	if absf(a - b) > eps:
		_fails += 1
		printerr("  FAIL: %s (%.5f vs %.5f, |Δ|=%.5f > %.5f)" % [label, a, b, absf(a - b), eps])


## A representative reach: 3 m-deep pond, 8" barrel siphon dropping ~9 m.
func _make_reach() -> HydroReach:
	var reach := HydroReach.new()
	# floor 100, rim 103 (3 m span), ~10 m² pond → 10 000 L/m, 30 000 L full.
	reach.set_pond(100.0, 103.0, 30000.0, 0.0)
	reach.configure_siphon({
		"intake_diameter_mm": 203.0,
		"outlet_diameter_mm": 203.0,
		"barrel_length_m": 20.0,
		"manning_n": 0.012,
		"max_power_w": 250.0,
		"hydraulic_efficiency": 0.6,
		"generator_efficiency": 0.7,
		"siphon_start_m": 102.5,   # prime when level reaches 102.5
		"siphon_break_m": 101.8,   # break when it falls to 101.8
		"outlet_invert_m": 93.0,   # ~9 m gross head
	})
	return reach


func _test_parity() -> void:
	print("[parity]")
	var reach := _make_reach()
	reach.set_pond_level(102.7)   # above prime
	reach.primed = true
	var r := reach.evaluate()
	# Independent reference straight through SiphonHydraulics.
	var ref := SiphonHydraulics.simulate(
		102.7, 101.8, 102.5, 93.0, 0.203, 0.203, 20.0, 0.012, true,
		250.0, 0.6, 0.7, 102.5, 101.8)
	_approx(float(r.get("q_lps", 0.0)), float(ref.get("q_lps", 0.0)), 1e-6,
		"evaluate Q matches simulate")
	_approx(float(r.get("power_w", 0.0)), float(ref.get("power_w", 0.0)), 1e-6,
		"evaluate power matches simulate")
	_approx(float(r.get("head_m", 0.0)), float(ref.get("head_m", 0.0)), 1e-6,
		"evaluate head matches simulate")
	_ok(bool(r.get("primed", false)), "primed above start")
	_ok(float(r.get("q_lps", 0.0)) > 0.0, "flows when primed with head")
	# Level parity: prismatic back-and-forth.
	reach.set_pond_level(101.5)
	_approx(reach.pond_level_m(), 101.5, 1e-4, "set_pond_level round-trips")


func _test_prime_break_cycle() -> void:
	print("[prime/break cycle]")
	var reach := _make_reach()
	# Start below break, empty-ish.
	reach.set_pond_level(101.0)
	reach.primed = false
	# Fill hard for a while (steady inflow), 1 s steps.
	var primed_seen := false
	for i in 400:
		var r := reach.step(1.0 / 3600.0, 40.0)   # 40 L/s in
		if bool(r.get("primed", false)):
			primed_seen = true
			break
	_ok(primed_seen, "siphon primes as pond fills past start")
	_ok(reach.primed, "primed flag latched")
	# Now cut inflow; it should keep flowing (primed) then break as level drops.
	var broke := false
	for i in 5000:
		var r := reach.step(1.0 / 3600.0, 0.0)
		if not bool(r.get("primed", false)):
			broke = true
			break
	_ok(broke, "siphon breaks after draining below break level")
	# Parks at the effective break (invert + ½-diameter submergence ≈ 101.9) — the
	# realistic dead pool the siphon can't pull past.
	_ok(reach.pond_level_m() <= reach.effective_break_level_m() + 0.05,
		"level parked at effective break after break")


func _test_mass_conservation() -> void:
	print("[mass conservation]")
	var reach := _make_reach()
	reach.set_pond_level(102.0)
	var initial := reach.pond_stock_l
	var inflow_lps := 12.0
	var dt_h := 1.0 / 3600.0
	var steps := 3000
	for i in steps:
		reach.step(dt_h, inflow_lps)
	var total_in := inflow_lps * 3600.0 * dt_h * float(steps)
	var accounted := reach.pond_stock_l + reach.cumulative_out_l + reach.overflow_l
	_approx(accounted, initial + total_in, 1.0, "stock + outlet + overflow == initial + inflow")
	_ok(reach.cumulative_out_l > 0.0, "outlet metered some volume")


func _test_break_floor() -> void:
	print("[break floor]")
	var reach := _make_reach()
	reach.set_pond_level(102.9)   # near full, above prime
	reach.primed = true
	# No inflow — drain to exhaustion.
	for i in 20000:
		reach.step(1.0 / 3600.0, 0.0)
	# Pond must not drain below the break level (siphon can't pull air).
	_ok(reach.pond_level_m() >= 101.8 - 0.02, "pond never drains below air-break level")
	_ok(not reach.primed, "ends un-primed")

	# A REAL basin (narrow at the bottom, wide on top): with its stage curve the
	# dead pool sits at the break LEVEL, not at the prismatic stock fraction —
	# a bowl holds most of its water high up, so the prism put Mt Vernon's dead
	# pool 0.67 m above the dip mouth and the siphon stalled early.
	var bowl := _make_reach()
	var curve := [[0.0, 100.0], [2000.0, 101.0], [8000.0, 102.0], [30000.0, 103.0]]
	bowl.set_stage_curve(curve)
	bowl.set_pond_level(102.9)
	bowl.primed = true
	for i in 20000:
		bowl.step(1.0 / 3600.0, 0.0)
	var eff := bowl.effective_break_level_m()
	_approx(bowl.pond_level_m(), eff, 0.02, "curved basin drains to the break level itself")
	_approx(bowl.pond_stock_l, PondBathymetry.stage_stock_for_level(curve, eff), 30.0,
			"curved basin dead pool = curve stock at the break level")
	bowl.set_pond(100.0, 103.0, 30000.0, 0.0)
	_ok(bowl.stage_curve.is_empty(), "set_pond clears a previous turbine's curve")


## drainable_lph() is the flow engine's mass-conserving drain clamp: it must never
## return more than the stock above the air-break can supply in one step, so the
## engine (which keeps net_rates as the tank integrator) can't over-credit the
## outlet at the dead-pool crossing. Away from the dead pool it's a pass-through.
func _test_drainable_lph() -> void:
	print("[drainable clamp]")
	var reach := _make_reach()
	reach.set_pond_level(102.9)   # near full, well above the dead pool
	reach.primed = true
	var r := reach.evaluate()
	var q_lph := float(r.get("q_lph", 0.0))
	_ok(q_lph > 0.0, "primed pond has flow")
	# Small dt, plenty of stock above break → no clamp (pass-through).
	_approx(reach.drainable_lph(q_lph, 1.0 / 3600.0), q_lph, 1e-6,
		"drainable == q_lph away from the dead pool")
	# Huge dt so q_lph×dt overshoots the stock above the break → clamped to exactly
	# that stock / dt (never more), and the clamp is strictly below the raw flow.
	var big_dt := 1000.0
	var avail := reach.stock_above_break()
	var clamped := reach.drainable_lph(q_lph, big_dt)
	_ok(clamped < q_lph, "drainable clamped below raw flow at the crossing")
	_approx(clamped * big_dt, avail, 1e-3, "drained volume == stock above break")
	# Right at the dead pool there is nothing left to pull.
	reach.set_pond_level(101.8)
	_approx(reach.drainable_lph(q_lph, 1.0 / 3600.0), 0.0, 1e-6,
		"no drain at the air-break level")


func _test_overflow() -> void:
	print("[overflow]")
	var reach := _make_reach()
	reach.set_pond(100.0, 103.0, 30000.0, 29500.0)   # nearly full
	reach.siphon_start_m = 200.0   # unreachably high → never primes/drains
	reach.siphon_break_m = 199.0
	reach.primed = false
	for i in 200:
		reach.step(1.0 / 3600.0, 100.0)   # hard fill
	_ok(reach.overflow_l > 0.0, "overflow accumulates at the rim")
	_approx(reach.pond_stock_l, reach.pond_capacity_l, 1.0, "stock clamped at capacity")


## A spec with NO turbine_kind must behave EXACTLY like an explicit siphon — the
## save-compat guarantee (old saves carry no turbine_kind key).
func _test_legacy_parity() -> void:
	print("[legacy parity]")
	var base := {
		"intake_diameter_mm": 203.0, "outlet_diameter_mm": 203.0,
		"barrel_length_m": 20.0, "manning_n": 0.012, "max_power_w": 250.0,
		"hydraulic_efficiency": 0.6, "generator_efficiency": 0.7,
		"siphon_start_m": 102.5, "siphon_break_m": 101.8, "outlet_invert_m": 93.0,
		"siphon_primed": true,
	}
	var siphon_kind := base.duplicate()
	siphon_kind["turbine_kind"] = "siphon"
	var a := HydroReach.evaluate_specs(102.7, base)          # no turbine_kind
	var b := HydroReach.evaluate_specs(102.7, siphon_kind)   # explicit siphon
	_ok(str(a.get("conveyance", "")) == "siphon", "no turbine_kind → siphon conveyance")
	_approx(float(a.get("q_lps", 0.0)), float(b.get("q_lps", 0.0)), 1e-9, "no-kind Q == siphon-kind Q")
	_approx(float(a.get("power_w", 0.0)), float(b.get("power_w", 0.0)), 1e-9, "no-kind power == siphon power")
	_ok(float(a.get("q_lps", 0.0)) > 0.0, "legacy spec still flows")


## Pelton penstock reach: same pond, intake near the floor, turbine ~32 m below.
func _make_penstock_reach(design_lps: float, cap_w: float) -> HydroReach:
	var reach := HydroReach.new()
	reach.set_pond(100.0, 103.0, 30000.0, 24000.0)   # level 102.4
	reach.configure_siphon({
		"turbine_kind": "pelton",
		"penstock_length_m": 60.0,
		"penstock_diameter_mm": 63.0,
		"pipe_roughness_mm": 0.0015,
		"design_flow_lps": design_lps,
		"generator_efficiency": 0.85,
		"max_power_w": cap_w,
		"siphon_break_m": 100.4,   # penstock intake invert (near pond floor)
		"outlet_invert_m": 70.0,   # ~32 m gross head at level 102.4
	})
	return reach


func _test_penstock_operating_point() -> void:
	print("[penstock operating point]")
	# Design-limited: a small design flow at high head is capped by the turbine.
	var d := _make_penstock_reach(3.0, 0.0)
	var rd := d.evaluate()
	_ok(str(rd.get("conveyance", "")) == "penstock", "pelton → penstock conveyance")
	_ok(float(rd.get("q_capacity_lps", 0.0)) > 3.0, "capacity exceeds a small design flow")
	_approx(float(rd.get("q_lps", 0.0)), 3.0, 1e-6, "design-limited: Q == design flow")
	_ok(float(rd.get("power_w", 0.0)) > 0.0, "penstock generates power")
	var nh := float(rd.get("net_head_m", 0.0))
	_ok(nh > 0.0 and nh < float(rd.get("head_m", 0.0)), "net head = gross minus friction loss")
	# Capacity-limited: a huge design flow → the pipe caps Q below design.
	var c := _make_penstock_reach(500.0, 0.0)
	var rc := c.evaluate()
	_ok(float(rc.get("q_lps", 0.0)) < 500.0, "capacity-limited: Q below the huge design flow")
	_approx(float(rc.get("q_lps", 0.0)), float(rc.get("q_capacity_lps", 0.0)), 1e-6,
		"capacity-limited: Q == pipe capacity")
	# Monotone: more head → more delivery capacity.
	c.set_pond_level(101.0)
	var lo := float(c.evaluate().get("q_capacity_lps", 0.0))
	c.set_pond_level(102.8)
	var hi := float(c.evaluate().get("q_capacity_lps", 0.0))
	_ok(hi > lo, "penstock capacity increases with head")


func _test_penstock_capacity_solve() -> void:
	print("[penstock f-solve]")
	var c := _make_penstock_reach(500.0, 0.0)   # capacity-limited so Q == capacity
	var r := c.evaluate()
	var q_cap := float(r.get("q_capacity_lps", 0.0))
	var head := float(r.get("head_m", 0.0))
	# Reconstruct the free-discharge energy balance H = (1+K+f·L/D)·v²/2g at the
	# solved capacity and confirm it round-trips to the gross head.
	var d := 0.063
	var l := 60.0
	var eps := 1.5e-6
	var k := 0.5
	var g := 9.80665
	var area := PI * d * d * 0.25
	var v := (q_cap / 1000.0) / area
	var f := HydroSource.darcy_friction_factor(v, d, eps)
	var h_recon := (1.0 + k + f * l / d) * v * v / (2.0 * g)
	_approx(h_recon, head, head * 0.03 + 0.05, "f-solve energy balance round-trips to gross head")


func _test_penstock_nameplate() -> void:
	print("[penstock nameplate]")
	var un := _make_penstock_reach(500.0, 0.0).evaluate()      # uncapped
	var cap := _make_penstock_reach(500.0, 200.0).evaluate()   # 200 W nameplate
	_ok(float(un.get("power_w", 0.0)) > 200.0, "uncapped exceeds the nameplate")
	_approx(float(cap.get("power_w", 0.0)), 200.0, 1e-6, "nameplate clamps power to max_power_w")


func _test_penstock_drawdown() -> void:
	print("[penstock drawdown]")
	var reach := _make_penstock_reach(500.0, 0.0)   # capacity-limited, real draw
	var initial := reach.pond_stock_l
	for i in 20000:
		reach.step(1.0 / 3600.0, 0.0)
		if float(reach.last.get("q_lps", 0.0)) < 1e-6 and reach.pond_level_m() < 101.0:
			break
	var accounted := reach.pond_stock_l + reach.cumulative_out_l
	_approx(accounted, initial, 2.0, "penstock: stock + outlet == initial (mass conserved)")
	# Parks at the intake dead pool (intake invert + ½ penstock-diameter band).
	_ok(reach.pond_level_m() >= 100.4 - 0.05, "penstock pond parks at the intake dead pool")
	_ok(reach.pond_level_m() < 101.5, "penstock actually drew the pond down")

## PowerSpout-class nozzle-governed Pelton through the SAME reach (Phase D):
## flow follows head + nozzle area (design_flow ignored by construction), RPM
## comes from the jet speed ratio (not the siphon rotor curve), the kind's
## 1.6 kW nameplate applies when the spec leaves max_power_w at 0, and the
## dead-pool/drawdown machinery is unchanged.
func _make_powerspout_reach(nozzle_mm: float, nozzle_n: int) -> HydroReach:
	var reach := HydroReach.new()
	reach.set_pond(100.0, 103.0, 30000.0, 24000.0)   # level 102.4
	reach.configure_siphon({
		"turbine_kind": "powerspout_pelton",
		"penstock_length_m": 100.0,
		"penstock_diameter_mm": 37.53,   # 1.5" SDR-9 poly ID
		"pipe_roughness_mm": 0.0015,
		"design_flow_lps": 500.0,        # must be IGNORED by the nozzle model
		"generator_efficiency": 0.85,
		"nozzle_count": nozzle_n,
		"nozzle_diameter_mm": nozzle_mm,
		"siphon_break_m": 100.4,
		"outlet_invert_m": 82.4,         # 20 m gross head at level 102.4
	})
	return reach


func _test_nozzle_model() -> void:
	print("[nozzle model (powerspout)]")
	var reach := _make_powerspout_reach(10.0, 1)
	var r := reach.evaluate()
	_ok(str(r.get("conveyance", "")) == "penstock", "powerspout → penstock conveyance")
	# Hand-computed operating point (20 m gross, 100 m of 1.5" SDR-9, 1x10 mm
	# nozzle, Cv 0.97): converges near h_net ~15.7 m, Q ~1.34 L/s, P ~114 W.
	var q := float(r.get("q_lps", 0.0))
	_ok(q > 1.2 and q < 1.5, "nozzle op point Q in the 1.2-1.5 L/s band (got %.3f)" % q)
	_ok(q < 500.0 * 0.99, "design_flow knob ignored by the nozzle model")
	var p := float(r.get("power_w", 0.0))
	_ok(p > 90.0 and p < 140.0, "power in the 90-140 W band (got %.1f)" % p)
	var h_net := float(r.get("net_head_m", 0.0))
	var h_loss := float(r.get("head_loss_m", 0.0))
	_approx(h_net + h_loss, float(r.get("head_m", 0.0)), 0.05,
		"nozzle op point: net + loss == gross")
	# RPM from the jet (u = 0.46 v_j, PCD 0.22 m) — hundreds of rpm, not the
	# siphon curve's tens.
	var rpm := float(r.get("rpm", 0.0))
	_ok(rpm > 500.0 and rpm < 900.0, "jet-derived rpm in the 500-900 band (got %.0f)" % rpm)
	# Bigger nozzle draws more water and more power at the same head.
	var big := _make_powerspout_reach(14.0, 1).evaluate()
	_ok(float(big.get("q_lps", 0.0)) > q, "bigger nozzle draws more flow")
	# Kind nameplate: 130 m head + twin fat nozzles on a short fat pipe would
	# pencil to multiple kW; the reach clamps at the kind's 1600 W (spec left
	# max_power_w unset).
	var hot := HydroReach.new()
	hot.set_pond(100.0, 103.0, 30000.0, 24000.0)
	hot.configure_siphon({
		"turbine_kind": "powerspout_pelton",
		"penstock_length_m": 10.0, "penstock_diameter_mm": 63.0,
		"pipe_roughness_mm": 0.0015, "generator_efficiency": 0.85,
		"nozzle_count": 2, "nozzle_diameter_mm": 12.0,
		"siphon_break_m": 100.4, "outlet_invert_m": -27.6,   # 130 m gross
	})
	var rh := hot.evaluate()
	_approx(float(rh.get("power_w", 0.0)), 1600.0, 1e-6,
		"kind nameplate clamps an unset max_power_w at 1.6 kW")
	# Dead pool unchanged: below the intake band the nozzle stops.
	reach.set_pond_level(100.41)
	var dry := reach.evaluate()
	_ok(float(dry.get("q_lps", 0.0)) < 1e-6, "nozzle stops at the dead pool")


## Levelless source (spring / creek tapped by a penstock). The reach used to bail
## with regime "unset" for exactly this setup because it only knew how to drain a
## stored pond, which is why a stream-fed PowerSpout read as dead in the Lab even
## while the graph estimator was producing power.
func _test_stream_source() -> void:
	print("[stream source (levelless)]")
	var base := {
		"turbine_kind": "powerspout_pelton",
		"penstock_source_mode": "stream",
		"gross_head_m": 20.0,
		"penstock_length_m": 100.0,
		"penstock_diameter_mm": 37.53,
		"pipe_roughness_mm": 0.0015,
		"generator_efficiency": 0.85,
		"nozzle_count": 1, "nozzle_diameter_mm": 10.0,
	}
	# No pond set AT ALL — the whole point.
	var amp := HydroReach.new()
	amp.configure_siphon(base)
	var ra := amp.evaluate()
	_ok(str(ra.get("regime", "")) == "penstock",
		"stream source runs without a pond (regime %s)" % str(ra.get("regime", "")))
	_approx(float(ra.get("head_m", 0.0)), 20.0, 1e-6, "stream head is the adopted drop")
	var qa := float(ra.get("q_lps", 0.0))
	_ok(qa > 1.2 and qa < 1.5, "unlimited stream matches the nozzle op point (%.3f L/s)" % qa)
	# The reach and the graph estimator must agree — they are the same physics and
	# the Lab reads one while the flow engine prices the other.
	var est_kw := HydroSource.power_kw_from_graph_specs(base, 6)
	_approx(float(ra.get("power_kw", 0.0)), est_kw, 0.002,
		"reach and estimator agree on a stream-fed PowerSpout")

	# Supply-limited: a 0.5 L/s spring cannot feed a 10 mm jet.
	var lim_specs: Dictionary = base.duplicate(true)
	lim_specs["supply_lps"] = 0.5
	var lim := HydroReach.new()
	lim.configure_siphon(lim_specs)
	var rl := lim.evaluate()
	_approx(float(rl.get("q_lps", 0.0)), 0.5, 1e-6, "flow caps at the spring's supply")
	_ok(bool(rl.get("supply_limited", false)), "reach reports supply_limited")
	_ok(float(rl.get("power_w", 0.0)) < float(ra.get("power_w", 0.0)) * 0.35,
		"supply-limited power collapses (oversized nozzle)")
	_ok(float(rl.get("unused_head_m", 0.0)) > 10.0,
		"most of the gross head goes unconverted (%.1f m)" % float(rl.get("unused_head_m", 0.0)))

	# A spring that stopped running is "no_supply", NOT "no_head" — the Lab must
	# not tell the player to move a correctly-sited turbine.
	var dry_specs: Dictionary = base.duplicate(true)
	dry_specs["supply_lps"] = 0.0
	var dry_reach := HydroReach.new()
	dry_reach.configure_siphon(dry_specs)
	var rd := dry_reach.evaluate()
	_ok(str(rd.get("regime", "")) == "no_supply" and float(rd.get("q_lps", 0.0)) == 0.0,
		"a dry spring reads no_supply, not no_head")

	# Regression: the POND path must be untouched by all of the above.
	var pond := _make_powerspout_reach(10.0, 1)
	var rp := pond.evaluate()
	_ok(str(rp.get("regime", "")) == "penstock"
		and float(rp.get("q_lps", 0.0)) > 1.2 and float(rp.get("q_lps", 0.0)) < 1.5,
		"pond-fed nozzle model unchanged by the stream mode")
