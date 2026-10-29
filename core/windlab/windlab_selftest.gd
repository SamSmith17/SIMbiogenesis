extends SceneTree

## Wind turbine designer self-test (offline). Run --import first.
##   Godot --headless --path . --script core/windlab/windlab_selftest.gd
## The spec (defaults, clamps, a JSON round trip keeping the key), the Cp
## curves (drag line peaking at λopt with Cp_max, zero at runaway, the lift
## curve's peak and dead band, Betz), the Ugrinsky paper's tables, the
## Wilson–Lissaman propeller Cp and Schmitz chord by hand, the Ugrinsky
## geometry (tangent S-bend, the lawn-sign build's measured shape), the
## generator (stepper constant, current ceiling, cut-in, DC by hand), the
## operating point (torque balance, power ≤ aero ≤ wind × Betz), start-up,
## the Rayleigh spread and the year's energy, gearing and generator ranking,
## the lawn-sign sheet (two blades + two discs on ONE 18 × 24 in sign, NEMA 17
## pattern, score lines), corrugation direction, the solids' winding and STL
## bytes, the builder's nodes, spin and picking, the cut files, the graph's
## wind node reading the designed curve, every built-in clean of errors.

const EXPECTED_CHECKS := 116

var _n := 0
var _fails := 0


func _check(ok: bool, what: String) -> void:
	_n += 1
	if not ok:
		_fails += 1
		print("  FAIL: ", what)


func _near(a: float, b: float, tol: float) -> bool:
	return absf(a - b) <= tol


func _initialize() -> void:
	WindLabDesign.clear_cache()
	_test_spec()
	_test_cp_curves()
	_test_ugrinsky_tables()
	_test_hawt_formulas()
	_test_ugrinsky_geometry()
	_test_generator()
	_test_operating_point()
	_test_energy()
	_test_matching()
	_test_lawn_sign_sheet()
	_test_flutes()
	_test_mesh_and_stl()
	_test_builder()
	_test_cam()
	_test_graph_handoff()
	_test_presets()
	print("windlab selftest: %d checks, %d failures" % [_n, _fails])
	if _n != EXPECTED_CHECKS:
		print("  FAIL: expected %d checks, ran %d (a test function aborted?)" % [EXPECTED_CHECKS, _n])
		_fails += 1
	print("WINDLAB SELFTEST %s" % ("PASS" if _fails == 0 else "FAIL"))
	quit(0 if _fails == 0 else 1)


func _test_spec() -> void:
	var s := WindLabSpec.default_spec()
	_check(str(s["type"]) == "ugrinsky" and int(s["rotor"]["blades"]) == 2, "default spec is a two-blade Ugrinsky")
	var bad := WindLabSpec.resolve({"type": "nonsense", "rotor": {"d_mm": -5.0, "blades": 99}, "generator": {"id": "x"}})
	_check(str(bad["type"]) == "ugrinsky" and float(bad["rotor"]["d_mm"]) >= 60.0 and int(bad["rotor"]["blades"]) <= 3,
		"an unknown type, a negative diameter and 99 blades are clamped")
	var mb := WindLabSpec.resolve({"type": "multiblade"})
	_check(int(mb["rotor"]["blades"]) >= 6, "a farm windmill gets many blades")
	var direct := WindLabSpec.resolve({"mount": {"style": "body_spins"}, "drive": {"type": "gt2"}})
	_check(str(direct["drive"]["type"]) == "direct", "a rotor clamped to the motor body has no drive")
	var js := JSON.parse_string(JSON.stringify(WindLabSpec.to_json_safe(WindLabPresets.lawn_sign_spec()))) as Dictionary
	_check(WindLabSpec.key_of(js) == WindLabSpec.key_of(WindLabPresets.lawn_sign_spec()), "the key survives a JSON round trip")


func _test_cp_curves() -> void:
	var m := {"family": "drag", "cp_max": 0.2, "lam_opt": 0.8, "lam_run": 1.6, "cq0": 0.5, "cq_start": 0.1, "dead_lo": 0.0, "dead_hi": 0.0}
	_check(_near(WindLabAero.cp_at(m, 0.8), 0.2, 1e-6), "the drag line peaks at Cp_max at λopt")
	_check(_near(WindLabAero.cp_at(m, 1.6), 0.0, 1e-9) and _near(WindLabAero.cp_at(m, 2.0), 0.0, 1e-9), "and is zero at runaway")
	_check(WindLabAero.cp_at(m, 0.7) < 0.2 and WindLabAero.cp_at(m, 0.9) < 0.2, "lower either side")
	_check(_near(WindLabAero.cq_at(m, 0.0), 0.5, 1e-9), "Cq at rest is the line's start")
	var l := {"family": "lift", "cp_max": 0.4, "lam_opt": 6.0, "lam_run": 12.0, "cq0": 0.133, "cq_start": 0.02, "dead_lo": 0.0, "dead_hi": 0.0}
	_check(_near(WindLabAero.cp_at(l, 6.0), 0.4, 1e-6) and WindLabAero.cp_at(l, 12.0) == 0.0, "the lift curve peaks at λopt and ends at 2·λopt")
	var dar := l.duplicate()
	dar["dead_lo"] = 0.22
	dar["dead_hi"] = 0.6
	dar["cq_start"] = 0.003
	_check(WindLabAero.cp_at(dar, 0.6) < 0.01 and WindLabAero.cp_at(dar, 6.0) > 0.39, "a Darrieus makes nearly nothing in its dead band")
	var s := WindLabSpec.resolve({"type": "savonius", "rotor": {"overlap": 0.15, "hub": {"style": "end_plates"}}})
	var cm := WindLabAero.cp_model(s)
	_check(_near(float(cm["cp_max"]), WindLabAero.SAV_CP, 1e-6), "a Savonius at the best overlap with end plates is the measured class")
	var s2 := WindLabSpec.resolve({"type": "savonius", "rotor": {"overlap": 0.45, "hub": {"style": "mid_discs"}}})
	_check(float(WindLabAero.cp_model(s2)["cp_max"]) < float(cm["cp_max"]) * 0.8, "a wide overlap and no end plates cost power")
	var big := WindLabSpec.resolve({"type": "hawt", "rotor": {"blades": 3, "tsr": 7.0, "airfoil": "sg6043", "d_mm": 20000.0}})
	_check(float(WindLabAero.cp_model(big)["cp_max"]) < WindLabAero.BETZ, "no rotor beats Betz")
	var two := WindLabSpec.resolve({"type": "savonius", "rotor": {"blades": 2, "stages": 1}})
	var twostage := WindLabSpec.resolve({"type": "savonius", "rotor": {"blades": 2, "stages": 2}})
	_check(float(WindLabAero.cp_model(twostage)["cq_start"]) > float(WindLabAero.cp_model(two)["cq_start"]),
		"two stages start at any angle (Blackwell et al.)")


func _test_ugrinsky_tables() -> void:
	var s := WindLabSpec.resolve({"type": "ugrinsky", "rotor": {"s_ratio": 0.35, "l_ratio": 1.0, "hub": {"style": "end_plates"}, "h_mm": 1200.0, "d_mm": 600.0}})
	var m := WindLabAero.cp_model(s)
	var want := WindLabAero.SAV_CP * 1.43 * 0.181 / 0.170
	_check(_near(float(m["cp_max"]), want, 1e-4), "Ugrinsky S = 0.35 D, L = 1.0 R: the paper's gain on a measured Savonius (%.3f)" % want)
	_check(_near(float(m["lam_opt"]), 0.5, 1e-6), "peaking at λ 0.5 (table 2)")
	var s45 := s.duplicate(true)
	s45["rotor"]["s_ratio"] = 0.45
	_check(float(WindLabAero.cp_model(s45)["cp_max"]) < float(m["cp_max"]) * 0.75, "S = 0.45 D falls off (0.123 in the paper)")
	var s13 := s.duplicate(true)
	s13["rotor"]["l_ratio"] = 1.3
	_check(float(WindLabAero.cp_model(s13)["cp_max"]) > float(m["cp_max"]), "L = 1.3 R the highest peak (0.185)")
	var out := s.duplicate(true)
	out["rotor"]["l_ratio"] = 0.6
	_check(not (WindLabAero.cp_model(out)["notes"] as Array).is_empty(), "outside the studied range says so")


func _test_hawt_formulas() -> void:
	# Wilson, Lissaman & Walker with an ideal section (L/D → ∞): B = 3, λ = 6.
	var lam := 6.0
	var b := 3.0
	var t1 := (16.0 / 27.0) * lam / (lam + (1.32 + pow((lam - 8.0) / 20.0, 2.0)) / pow(b, 2.0 / 3.0))
	_check(_near(t1, 0.5359, 0.001), "Wilson–Lissaman ideal Cp at λ 6, 3 blades = 0.536 (%.4f)" % t1)
	var s := WindLabSpec.resolve({"type": "hawt", "rotor": {"blades": 3, "tsr": 6.0, "airfoil": "sg6043", "d_mm": 1200.0, "hub_frac": 0.12}})
	var hc := WindLabAero.hawt_cp(s, 6.0)
	_check(float(hc["cp"]) < t1 and float(hc["cp"]) > 0.35, "drag at the blade's Reynolds number takes some off")
	var st := WindLabAero.hawt_blade(s)
	var mid: Dictionary = st[6]
	var rr := float(mid["r_m"])
	var lr := 6.0 * rr / 0.6
	var phi := (2.0 / 3.0) * atan(1.0 / lr)
	var c := 16.0 * PI * rr / (3.0 * 1.1) * pow(sin(phi * 0.5), 2.0)
	_check(_near(float(mid["c_m"]), c, 1e-6), "Schmitz chord at mid span by hand (%.1f mm)" % (c * 1000.0))
	_check(_near(float(mid["twist_deg"]), rad_to_deg(phi) - 5.0, 1e-4), "twist = φ − α")
	_check(float((st[0] as Dictionary)["twist_deg"]) > float((st[st.size() - 1] as Dictionary)["twist_deg"]), "the blade twists flatter toward the tip")
	_check(float((st[1] as Dictionary)["c_m"]) > float((st[st.size() - 2] as Dictionary)["c_m"]), "and narrows")


func _test_ugrinsky_geometry() -> void:
	var s := WindLabPresets.lawn_sign_spec()
	var g := WindLabAero.ugrinsky_geom(s)
	var R := float(g["R"])
	# The lawn sign measures: tip radius 3.567 in, S = 2.55 in, L = 3.0 in,
	# inner end 0.9 in from the shaft, tail tip 2.88 in out, unrolled ~7.8 in.
	_check(_near(R / WindLabParts.IN, 3.567, 0.01), "the lawn sign's rotor radius 3.57 in")
	_check(_near(float(g["S"]) / WindLabParts.IN, 2.57, 0.05), "semicircle S ≈ 2.55 in")
	_check(_near(float(g["L"]) / WindLabParts.IN, 3.0, 0.05), "tail arc L ≈ 3.0 in")
	_check(_near(float(g["tip_r"]) / WindLabParts.IN, 2.88, 0.25), "tail tip ≈ 2.9 in from the shaft")
	_check(_near(float(g["dev_mm"]) / WindLabParts.IN, 7.8, 0.15), "a blade unrolls to ~7.8 in (%.2f)" % (float(g["dev_mm"]) / WindLabParts.IN))
	var blades := WindLabAero.vawt_blades(s)
	var pts: PackedVector2Array = blades[0]["pts"]
	# Tangent continuity at the junction (semicircle end → tail start).
	var j := 24
	var t_in := (pts[j] - pts[j - 1]).normalized()
	var t_out := (pts[j + 1] - pts[j]).normalized()
	_check(t_in.dot(t_out) > 0.97, "the semicircle runs smoothly into the tail arc (an S-bend)")
	_check(_near(pts[0].length(), R, 0.5), "the semicircle starts on the rim")
	_check(not WindLabAero.blades_clash(blades, 4.0), "the two blades do not touch")
	var b1: PackedVector2Array = blades[1]["pts"]
	_check(_near((b1[5] + pts[5]).length(), 0.0, 1e-3), "the second blade is the first turned half a turn")


func _test_generator() -> void:
	var g := WindLabParts.generator("nema17_48")
	var k := WindLabGen.emf_constant(g)
	_check(_near(k, 0.59 / (sqrt(2.0) * 2.0), 1e-9), "stepper EMF constant = T_hold / (√2·I)")
	_check(_near(WindLabGen.current_ceiling(g), k / (50.0 * 0.003), 1e-9), "its current levels off at K / (p·L)")
	var load := {"type": "battery", "battery_v": 12.0, "diode": "schottky"}
	var lo := WindLabGen.operate(g, load, 300.0)
	_check(float(lo["p_load"]) == 0.0, "no charge until the EMF passes the battery + diodes")
	var hi := WindLabGen.operate(g, load, 1500.0)
	_check(float(hi["p_load"]) > 0.0 and float(hi["i_ph"]) < WindLabGen.current_ceiling(g) * 1.01, "it charges at speed, under its ceiling")
	_check(float(hi["torque_nm"]) * 1500.0 * TAU / 60.0 >= float(hi["p_load"]), "shaft power ≥ power delivered")
	var dc := WindLabParts.generator("treadmill")
	var dl := {"type": "battery", "battery_v": 24.0, "diode": "silicon"}
	var o := WindLabGen.operate(dc, dl, 3000.0)
	var e := float(dc["v_per_rpm"]) * 3000.0
	var i := (e - 24.0 - 0.9 - 1.5) / 1.2
	_check(_near(float(o["i_dc"]), i, 1e-6), "brushed DC by hand: I = (E − V − diode − brushes) / R")
	var mp := {"type": "mppt", "battery_v": 12.0, "mppt_min_v": 8.0, "mppt_eff": 0.95, "diode": "schottky"}
	var r := WindLabGen.mppt_from_em(g, mp, 1200.0, 10.0)
	_check(bool(r["ok"]) and float(r["p_load"]) < 10.0 and float(r["p_load"]) > 5.0, "the MPPT delivers what the magnets take less the losses")
	var t := WindLabGen.table("nema17_48", load, 1)
	_check(_near(WindLabGen.lookup(t, 1500.0, "p_load"), float(hi["p_load"]), float(hi["p_load"]) * 0.05 + 0.05), "the cached table reads the circuit back")


func _test_operating_point() -> void:
	var d := WindLabDesign.solve(WindLabPresets.ugrinsky_1m_spec())
	var op := WindLabDesign.op_point(d, 7.0)
	_check(bool(op["running"]), "the 0.6 × 1.2 m Ugrinsky turns at 7 m/s")
	var cp: Dictionary = d["cp"]
	var q := 0.5 * float(d["rho"]) * 49.0 * float(d["area_m2"]) * float(d["R_m"])
	var ta := WindLabAero.cq_at(cp, float(op["lam"])) * q
	var tl := WindLabDesign._load_torque(d, WindLabDesign._gen_table(d), float(op["w"]))
	_check(_near(ta, tl, maxf(ta * 0.03, 0.01)), "the rotor's torque meets the generator's there (%.3f vs %.3f N·m)" % [ta, tl])
	_check(float(op["p_elec"]) <= float(op["p_aero"]) + 1e-6 and float(op["p_aero"]) <= float(op["p_wind"]) * WindLabAero.BETZ,
		"electrical ≤ shaft ≤ wind × Betz")
	var below := WindLabDesign.op_point(d, maxf(float(d["start_ms"]) - 1.0, 0.5))
	_check(not bool(below["running"]), "it stands still below its start wind")
	var above := WindLabDesign.op_point(d, float(d["start_ms"]) + 0.5)
	_check(bool(above["running"]), "and turns just above it")
	var a := WindLabDesign.op_point(d, 5.0)
	var b := WindLabDesign.op_point(d, 9.0)
	_check(float(b["rpm"]) > float(a["rpm"]) and float(b["p_elec"]) > float(a["p_elec"]), "more wind, faster and more power")
	var dar := WindLabDesign.solve(WindLabPresets.darrieus_spec())
	_check(bool(WindLabDesign.op_point(dar, 8.0)["assisted"]), "a Darrieus runs at 8 m/s only pushed up to speed")


func _test_energy() -> void:
	var sum := 0.0
	var v := 0.05
	while v < 40.0:
		sum += WindLabDesign.rayleigh(v, 5.0) * 0.1
		v += 0.1
	_check(_near(sum, 1.0, 0.01), "the Rayleigh spread integrates to 1")
	var mean := 0.0
	v = 0.05
	while v < 40.0:
		mean += v * WindLabDesign.rayleigh(v, 5.0) * 0.1
		v += 0.1
	_check(_near(mean, 5.0, 0.05), "with the mean it was given")
	var d := WindLabDesign.solve(WindLabPresets.hawt_printed_spec())
	_check(float(d["aep_kwh"]) > 0.0 and float(d["aep_kwh"]) < float(d["peak_w"]) * 8.76, "a year's energy is positive and below running flat out")
	var s2 := WindLabPresets.hawt_printed_spec()
	s2["mount"]["mast_h_mm"] = 12000.0
	_check(float(WindLabDesign.solve(s2)["aep_kwh"]) > float(d["aep_kwh"]), "a taller mast sees more wind")
	var s3 := WindLabPresets.hawt_printed_spec()
	s3["site"]["mean_wind_ms"] = 6.0
	_check(float(WindLabDesign.solve(s3)["aep_kwh"]) > float(d["aep_kwh"]) * 1.5, "a windier site makes much more")


func _test_matching() -> void:
	var s := WindLabPresets.ugrinsky_1m_spec()
	var b := WindLabDesign.best_ratio(s, "nema23_76")
	var at1 := WindLabDesign.evaluate(s, "nema23_76", 1.0)
	_check(float(b["aep_kwh"]) >= float(at1["aep_kwh"]), "the best ratio beats 1 : 1")
	_check(float(b["ratio"]) > 1.5, "a slow drag rotor wants stepping up (%.2f)" % float(b["ratio"]))
	var dr := WindLabDesign.drive_for_ratio(s, 3.0)
	_check(_near(float(dr["ratio"]), 3.0, 0.15) and int(dr["driven_teeth"]) >= 16, "a GT2 pulley pair near 3 : 1")
	var dp := WindLabDesign.drive_for_ratio(WindLabSpec.resolve({"mount": {"style": "bearings"}, "drive": {"type": "planetary"}}), 9.0)
	_check(_near(float(dp["planetary_ratio"]), 10.0, 0.01), "the nearest stock planetary ratio")
	var rk := WindLabDesign.rank_generators(WindLabPresets.lawn_sign_spec())
	var sorted := true
	for i in range(1, rk.size()):
		if float(rk[i]["aep_kwh"]) > float(rk[i - 1]["aep_kwh"]) + 1e-9:
			sorted = false
	_check(rk.size() == WindLabParts.GENERATORS.size() and sorted, "every generator ranked, best first")
	_check(_near(float(rk[0]["ratio"]), 1.0, 1e-9), "a rotor clamped to the motor ranks generators at 1 : 1")
	_check(str(rk[0]["gen"]).begins_with("nema17") or str(rk[0]["gen"]) == "rs555", "the lawn sign's best is a small motor (%s)" % str(rk[0]["gen"]))


func _test_lawn_sign_sheet() -> void:
	var d := WindLabDesign.solve(WindLabPresets.lawn_sign_spec())
	var sheets: Array = d["nest"]["sheets"]
	_check(sheets.size() == 1 and (d["nest"]["unplaced"] as Array).is_empty(), "the lawn-sign turbine comes out of ONE 18 × 24 in sign")
	var n := 0
	for sh in sheets:
		n += (sh["placements"] as Array).size()
	_check(n == 4, "two blades and two discs")
	var blade := {}
	var hub := {}
	for p in d["parts"]:
		if str(p["id"]) == "blade":
			blade = p
		if str(p["id"]) == "hub":
			hub = p
	_check(_near(float(hub["w"]), 8.0 * WindLabParts.IN, 0.5), "8 in hub discs")
	_check(_near(float(blade["h"]), 455.5, 0.5) and float(blade["h"]) <= 18.0 * WindLabParts.IN, "blades the sign's 18 in less the kerf")
	_check(not (blade["fold"] as Array).is_empty(), "the tight semicircle is scored")
	# NEMA 17: a 22 mm boss and four holes on a 31 mm square.
	var holes := 0
	var c := Vector2(float(hub["w"]) * 0.5, float(hub["h"]) * 0.5)
	for ring in hub["inside"]:
		var bb := FlatpackProfile.ring_bbox(ring)
		var ctr := bb.get_center() - c
		if _near(absf(ctr.x), 15.5, 0.1) and _near(absf(ctr.y), 15.5, 0.1):
			holes += 1
	_check(holes == 4, "four M3 holes on the NEMA 17's 31 mm square")
	_check((hub["inside"] as Array).size() == 7, "two blade slots, the boss and four holes in each disc")
	var cnt := 0
	for ch in d["checks"]:
		if str(ch["level"]) == "error":
			cnt += 1
	_check(cnt == 0, "no errors on the lawn sign")


func _test_flutes() -> void:
	var s := WindLabPresets.ugrinsky_1m_spec()
	var d := WindLabDesign.solve(s)
	var turned: Dictionary = d["nest"].get("turned", {})
	_check(turned.has("blade#0"), "on a 4 × 8 sheet (flutes along its length) the blades lie along the sheet")
	var sign := WindLabDesign.solve(WindLabPresets.lawn_sign_spec())
	_check((sign["nest"].get("turned", {}) as Dictionary).is_empty(), "on a lawn sign (flutes along its height) they stand")
	var c := WindLabCam.sheet_content(d, 0)
	var sz := WindLabParts.sheet_size("sheet_4x8")
	var inside := true
	for ring in c["outside"]:
		var bb := FlatpackProfile.ring_bbox(ring)
		if bb.position.x < -0.5 or bb.position.y < -0.5 or bb.end.x > float(sz["w"]) + 0.5 or bb.end.y > float(sz["h"]) + 0.5:
			inside = false
	_check(inside, "every part on the sheet")


func _test_mesh_and_stl() -> void:
	var tris := WindLabMesh.ring(10.0, 0.0, 0.0, 5.0, 64)
	_check(_near(WindLabMesh.signed_volume(tris), PI * 100.0 * 5.0, PI * 100.0 * 5.0 * 0.01), "a disc's volume (and outward winding)")
	var line := PackedVector2Array([Vector2(0, 0), Vector2(50, 0), Vector2(100, 0)])
	var band := WindLabMesh.sheet_blade(line, 4.0, 0.0, 200.0)
	_check(_near(WindLabMesh.signed_volume(band), 100.0 * 4.0 * 200.0, 1.0), "a flat blade is length × thickness × height")
	var curved: PackedVector2Array = WindLabAero.vawt_blades(WindLabPresets.lawn_sign_spec())[0]["pts"]
	var cb := WindLabMesh.sheet_blade(curved, 4.0, 0.0, 100.0, 0.3)
	_check(WindLabMesh.signed_volume(cb) > 0.0, "a curved, twisted blade is a positive solid")
	var st := WindLabAero.hawt_blade(WindLabPresets.hawt_printed_spec())
	var hb := WindLabMesh.hawt_blade(st, WindLabAero.airfoil_points(WindLabParts.airfoil("sg6043"), 16))
	_check(WindLabMesh.signed_volume(hb) > 0.0, "a propeller blade is a positive solid")
	var bytes := WindLabMesh.stl_bytes(tris)
	_check(bytes.size() == 84 + 50 * (tris.size() / 3), "binary STL: 84 + 50 bytes a triangle")
	var pl := WindLabMesh.plate(PackedVector2Array([Vector2(0, 0), Vector2(0, 10), Vector2(10, 10), Vector2(10, 0)]), 0.0, 2.0)
	_check(_near(WindLabMesh.signed_volume(pl), 200.0, 0.01), "a plate from a clockwise outline still comes out positive")


func _test_builder() -> void:
	var b := WindLabBuilder.build_node(WindLabPresets.lawn_sign_spec()) as WindLabBuilder
	root.add_child(b)
	_check(b.get_node_or_null("Machine/Static") != null and b.get_node_or_null("Machine/Rotor") != null, "a vertical rotor's nodes")
	var rt := b.get_node("Machine/Rotor/RotorParts") as MeshInstance3D
	_check(rt.mesh != null and rt.mesh.get_surface_count() >= 2 and bool(rt.get_meta("skip_prop_collision", false)),
		"blades + hub on the spinning node, no collision")
	var aabb := rt.mesh.get_aabb()
	_check(_near(aabb.size.y, 0.4555, 0.02), "the blades stand 455 mm")
	b.set_spin_rpm(60.0)
	b._process(0.25)
	_check(not b.rotor().transform.basis.is_equal_approx(Basis.IDENTITY), "spinning turns the rotor")
	var hit := WindLabBuilder.pick(b, Vector3(0.0, 0.66, -3.0), Vector3(0, 0, 1))
	_check(not hit.is_empty(), "picking names a part (%s)" % str(hit.get("label", "")))
	b.free()
	var h := WindLabBuilder.build_node(WindLabPresets.hawt_printed_spec()) as WindLabBuilder
	root.add_child(h)
	_check(h.get_node_or_null("Machine/Yaw/Rotor") != null and h.yaw_node() != null, "a propeller yaws with its rotor")
	h.set_yaw(1.0)
	_check(_near(h.yaw_node().rotation.y, 1.0, 1e-6), "set_yaw turns the nacelle")
	var hr := h.get_node("Machine/Yaw/Rotor/RotorParts") as MeshInstance3D
	_check(_near(hr.mesh.get_aabb().end.x, 0.6, 0.05), "the first blade's tip reaches the 0.6 m radius")
	h.free()
	for id in ["savonius", "lenz2", "darrieus_h", "helical", "farm", "hawt_pvc"]:
		var spec := WindLabPresets.by_id(id if id != "savonius" else "oil_drum")
		var bb := WindLabBuilder.build_node(spec)
		var rr := bb.find_child("RotorParts", true, false) as MeshInstance3D
		_check(rr != null and rr.mesh != null and rr.mesh.get_surface_count() > 0, "%s builds a rotor" % id)
		bb.free()


func _test_cam() -> void:
	var d := WindLabDesign.solve(WindLabPresets.lawn_sign_spec())
	var c := WindLabCam.sheet_content(d, 0)
	_check((c["outside"] as Array).size() == 4 and (c["fold"] as Array).size() > 0, "the sheet carries four outlines and the score lines")
	var dxf := DomeLabCam.dxf_document(c)
	_check(dxf.contains("FOLD") and dxf.contains("OUTSIDE_CUT") and dxf.contains("INSIDE_CUT"), "the DXF has its cut and score layers")
	var dir := OS.get_user_data_dir().path_join("windlab_selftest_tmp")
	var r := WindLabCam.write_all(WindLabDesign.solve(WindLabPresets.hawt_printed_spec()), dir)
	_check(bool(r["ok"]) and (r["stl"] as Dictionary).has("hawt_blade"), "files written, a blade STL among them")
	var tris := StlLoader.load_triangles(str(r["stl"]["hawt_blade"]))
	_check(tris.size() > 100, "the blade STL reads back (%d)" % tris.size())
	var r2 := WindLabCam.write_all(d, dir)
	_check(bool(r2["ok"]) and (r2["stl"] as Dictionary).has("blade_print"), "a sheet rotor also gets a printable blade")
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)
	var csv := WindLabCam.power_curve_csv(d)
	_check(csv.split("\n").size() > 50, "the power curve CSV")


func _test_graph_handoff() -> void:
	var d := WindLabDesign.solve(WindLabPresets.ugrinsky_1m_spec())
	var patch := WindLabDesign.graph_patch(d)
	var specs := patch.duplicate(true)
	specs["hub_height_m"] = 10.0
	var kw := WindTurbineSource.power_kw_from_graph_specs(specs, 12.0, 7.0)
	var want := WindLabDesign.op_point(d, 7.0)
	_check(_near(kw * 1000.0, float(want["p_elec"]), 0.5), "the graph's wind node makes the designed watts at 7 m/s (%.2f vs %.2f W)" % [kw * 1000.0, float(want["p_elec"])])
	var past := WindTurbineSource.power_kw_from_graph_specs(specs, 12.0, float(d["cut_out_ms"]) + 2.0)
	_check(past == 0.0, "nothing past cut-out")
	_check(_near(WindTurbineSource.curve_at(patch["rpm_curve"], 7.0), float(want["rpm"]), 1.0), "the speed curve the 3D spin follows")
	var plain := {"kind": "hawt", "rated_w": 1000.0, "rotor_diameter_m": 2.1, "cp_peak": 0.42, "cut_in_ms": 3.0, "rated_ms": 11.0,
		"cut_out_ms": 20.0, "hub_height_m": 10.0}
	_check(WindTurbineSource.power_kw_from_graph_specs(plain, 12.0, 8.0) > 0.0, "a plain wind node still uses its own model")
	var pk := WindLabDesign.packed_spec(d)
	_check(float(pk["w_m"]) > 0.0 and float(pk["mass_kg"]) > 0.0, "the kit packs")
	var ports := WindLabDesign.ports(d)
	_check(ports.size() == 2 and str(ports[0]["handle"]) == "positive", "DC + / − ports on the wind node's handles")
	var p := ComponentPresets.designed_wind_preset(WindLabPresets.lawn_sign_spec())
	_check(not p.is_empty() and (p["specs"] as Dictionary).get("power_curve_w", null) is Array, "the designed preset carries the curve")


func _test_presets() -> void:
	for b in WindLabPresets.builtins():
		var d := WindLabDesign.solve(b["spec"])
		var errs: Array = []
		for c in d["checks"]:
			if str(c["level"]) == "error":
				errs.append(str(c["text"]))
		_check(errs.is_empty(), "%s solves without errors %s" % [str(b["id"]), str(errs)])
