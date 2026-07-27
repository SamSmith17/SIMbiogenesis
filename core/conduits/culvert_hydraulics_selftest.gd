extends SceneTree

## Offline self-test for CulvertHydraulics + HydroSectionCalculator.
## Run (after --import so class_names register):
##   Godot.exe.exe --headless --path . --script core/conduits/culvert_hydraulics_selftest.gd

var _failures: int = 0
var _checks: int = 0


func _initialize() -> void:
	_test_segment_area()
	_test_manning()
	_test_stage_curve()
	_test_stepped_bank()
	_test_hydro_section()
	if _failures == 0:
		print("CULVERT HYDRAULICS SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("CULVERT HYDRAULICS SELFTEST FAIL  (%d of %d checks failed)" % [
			_failures, _checks])
		quit(1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if ok:
		return
	_failures += 1
	if detail.is_empty():
		print("  FAIL: %s" % label)
	else:
		print("  FAIL: %s  (%s)" % [label, detail])


func _test_segment_area() -> void:
	var r := 0.1
	_check("segment empty", CulvertHydraulics.circular_segment_area(r, 0.0) < 1e-9)
	var full := CulvertHydraulics.circular_segment_area(r, 2.0 * r)
	_check("segment full", absf(full - PI * r * r) < 1e-6, "A=%.6f" % full)
	var half := CulvertHydraulics.circular_segment_area(r, r)
	_check("segment half", absf(half - 0.5 * PI * r * r) < 1e-4, "A=%.6f" % half)


func _test_manning() -> void:
	var q := CulvertHydraulics.manning_full_m3s(0.203, 0.02, 0.012)
	_check("manning positive", q > 0.01, "Q=%.4f" % q)
	var steeper := CulvertHydraulics.manning_full_m3s(0.203, 0.08, 0.012)
	_check("manning steeper > flat", steeper > q)


func _test_stage_curve() -> void:
	var inv_in := 100.0
	var inv_out := 91.0  # ~30 ft
	var d := CulvertHydraulics.diameter_m_from_size_in(8.0)
	var dry := CulvertHydraulics.stage_discharge(99.9, inv_in, inv_out, d, 15.0)
	_check("dry below invert", float(dry.get("q_lps", 1.0)) < 1e-6)
	var first := CulvertHydraulics.stage_discharge(100.05, inv_in, inv_out, d, 15.0)
	_check("first trickle", float(first.get("q_lps", 0.0)) > 0.01,
			"Q=%.3f" % float(first.get("q_lps", 0.0)))
	var mid := CulvertHydraulics.stage_discharge(100.15, inv_in, inv_out, d, 15.0)
	_check("mid > trickle", float(mid.get("q_lps", 0.0)) > float(first.get("q_lps", 0.0)))
	var full := CulvertHydraulics.stage_discharge(100.30, inv_in, inv_out, d, 15.0)
	_check("submerged open", float(full.get("q_lps", 0.0)) > float(mid.get("q_lps", 0.0)))
	_check("pe positive", float(full.get("pe_kw", 0.0)) > 0.0)
	_check("8in diameter", absf(d - 0.2032) < 0.001, "d=%.4f" % d)
	# Gravity gate: an outlet invert ABOVE the pond surface must not discharge
	# (no uphill drain). Inlet still submerged (d_over > 0), outlet raised high.
	var uphill := CulvertHydraulics.stage_discharge(100.20, inv_in, 100.5, d, 15.0)
	_check("no uphill discharge", float(uphill.get("q_lps", 1.0)) < 1e-6,
			"Q=%.3f" % float(uphill.get("q_lps", 0.0)))
	# Outlet just below the surface still flows (sanity that the gate isn't over-eager).
	var barely := CulvertHydraulics.stage_discharge(100.20, inv_in, 100.1, d, 15.0)
	_check("downhill still discharges", float(barely.get("q_lps", 0.0)) > 0.0)


func _test_stepped_bank() -> void:
	# Three 8″ culverts at stepped inverts (Mt Vernon pattern).
	var culverts := [
		{"invert_in_m": 100.0, "invert_out_m": 91.0, "diameter_m": 0.203, "length_m": 15.0},
		{"invert_in_m": 100.25, "invert_out_m": 91.1, "diameter_m": 0.203, "length_m": 15.0},
		{"invert_in_m": 100.50, "invert_out_m": 91.2, "diameter_m": 0.203, "length_m": 15.0},
	]
	var b0 := CulvertHydraulics.stage_discharge_bank(99.9, culverts)
	_check("bank dry", int(b0.get("open_count", 9)) == 0)
	var b1 := CulvertHydraulics.stage_discharge_bank(100.1, culverts)
	_check("bank first open", int(b1.get("open_count", 0)) == 1,
			"n=%d" % int(b1.get("open_count", 0)))
	var b2 := CulvertHydraulics.stage_discharge_bank(100.35, culverts)
	_check("bank two open", int(b2.get("open_count", 0)) == 2)
	var b3 := CulvertHydraulics.stage_discharge_bank(100.7, culverts)
	_check("bank all three", int(b3.get("open_count", 0)) == 3)
	_check("bank Q grows", float(b3.get("q_lps", 0.0)) > float(b1.get("q_lps", 0.0)))


func _test_hydro_section() -> void:
	var culverts := [
		{"invert_in_m": 10.0, "invert_out_m": 1.0, "diameter_m": 0.203, "length_m": 15.0},
		{"invert_in_m": 10.2, "invert_out_m": 1.1, "diameter_m": 0.203, "length_m": 15.0},
		{"invert_in_m": 10.4, "invert_out_m": 1.2, "diameter_m": 0.203, "length_m": 15.0},
	]
	var pot := HydroSectionCalculator.evaluate(10.5, culverts)
	_check("section potential mode", str(pot.get("mode", "")) == "potential")
	_check("section open 3", int(pot.get("open_count", 0)) == 3)
	_check("section head ~9+", float(pot.get("gross_head_m", 0.0)) > 8.0)
	_check("section pe > 0", float(pot.get("pe_kw", 0.0)) > 0.0)
	var hydro := {
		"gross_head_m": 9.0,
		"design_flow_lps": 20.0,
		"penstock_diameter_mm": 200.0,
		"penstock_length_m": 10.0,
		"kind": "pelton",
		"lock_design_flow": true,  # keep 20 L/s so friction doesn't wipe head
		"monthly_flow_multipliers": [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1],
	}
	var gen := HydroSectionCalculator.evaluate(10.5, culverts, hydro)
	_check("section gen mode", str(gen.get("mode", "")) == "generation")
	_check("section gen_kw > 0", float(gen.get("gen_kw", 0.0)) > 0.0,
			"kw=%.4f" % float(gen.get("gen_kw", 0.0)))
	# PE vs HydroSource at pinned head/Q should be in the same ballpark order.
	var pinned := HydroSource.power_kw_from_graph_specs({
		"gross_head_m": 9.0,
		"design_flow_lps": float(gen.get("live_q_lps", 1.0)),
		"penstock_diameter_mm": 200.0,
		"penstock_length_m": 5.0,
		"kind": "pelton",
		"turbine_efficiency": 1.0,
		"generator_efficiency": 1.0,
		"monthly_flow_multipliers": [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1],
	}, 6)
	var pe := float(gen.get("pe_kw", 0.0))
	_check("hydro ≤ PE (η≤1)", pinned <= pe * 1.05 + 0.01,
			"gen=%.3f pe=%.3f" % [pinned, pe])
