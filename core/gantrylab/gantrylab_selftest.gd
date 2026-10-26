extends SceneTree
## Gantry lab selftest (offline, deterministic):
##   Godot.exe.exe --headless --path . --script core/gantrylab/gantrylab_selftest.gd
## Pins: the parts tables (every id resolves, cited numbers in range), the
## spec (defaults, clamps, shared-belt coupling, key stability, JSON round
## trip), steps/mm against the printer-community reference values (GT2 20T
## 16 µsteps = 80 steps/mm; Tr8×8 = 400; Tr8×2 = 1600), CoreXY / H-bot /
## CoreXZ inverse kinematics, the delta inverse and its forward trilateration
## round trip + reach, torque → force → acceleration, belt stretch, screw
## critical speed, beam sag against a hand-computed value, the G-code parser
## (arcs, relative moves, G92, grbl laser, bounds, layers, to_toolpath), the
## motion planner (trapezoid times by hand, scrubbing monotone, corner
## slow-down, step-rate peak), every layout (assemblies, poses, belts),
## every preset solving with no error-level check, the BOM (cut list, cost,
## motors), the graph preset, the exports, the samples parsing. Carries
## EXPECTED_CHECKS: a runtime error aborts a test function while PASS prints.
## --import first so the class_names register.

const EXPECTED_CHECKS := 227
var _pass := 0
var _fail := 0


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
		print("  FAIL: %s %s" % [name, detail])


func _approx(a: float, b: float, tol: float) -> bool:
	return absf(a - b) <= tol


func _initialize() -> void:
	print("GantryLab selftest")
	_test_parts()
	_test_spec()
	_test_kinematics()
	_test_delta()
	_test_physics()
	_test_gcode()
	_test_motion()
	_test_layouts()
	_test_presets_and_bom()
	_test_exports_and_samples()
	_test_builder()
	var total := _pass + _fail
	print("GantryLab selftest: %d checks, %d passed, %d failed" % [total, _pass, _fail])
	if total != EXPECTED_CHECKS:
		print("  FAIL: expected %d checks, ran %d (a test function aborted?)" % [EXPECTED_CHECKS, total])
		_fail += 1
	print("RESULT: %s" % ("PASS" if _fail == 0 else "FAIL"))
	quit(0 if _fail == 0 else 1)


func _test_parts() -> void:
	for id in GantryLabParts.PROFILE_ORDER:
		var p := GantryLabParts.profile(id)
		_check("profile %s" % id, float(p["kg_m"]) > 0.3 and float(p["kg_m"]) < 3.0 and float(p["ix_cm4"]) > 0.0)
	_check("2040 strong I > weak I", float(GantryLabParts.PROFILES["2040"]["ix_cm4"]) > float(GantryLabParts.PROFILES["2040"]["iy_cm4"]))
	_check("profile_i_m4 converts cm4", _approx(GantryLabParts.profile_i_m4("2020"), 0.72e-8, 1e-12))
	for id in GantryLabParts.DRIVE_ORDER:
		var d := GantryLabParts.drive(id)
		_check("drive %s has eff" % id, float(d["eff"]) > 0.2 and float(d["eff"]) <= 1.0)
	for id in GantryLabParts.MOTOR_ORDER:
		_check("motor %s" % id, float(GantryLabParts.motor(id)["torque_nm"]) > 0.0)
	for id in GantryLabParts.TOOL_ORDER:
		var t := GantryLabParts.tool(id)
		_check("tool %s bed exists" % id, GantryLabParts.BEDS.has(str(t["bed"])))
	_check("unknown ids fall back", str(GantryLabParts.profile("nope")["label"]) == "V-slot 2020" and str(GantryLabParts.board("x")["label"]).begins_with("BTT SKR Mini"))


func _test_spec() -> void:
	var s := GantryLabSpec.default_spec("corexy")
	_check("default corexy", str(s["kinematics"]) == "corexy" and float(s["volume"]["x_mm"]) == 220.0)
	_check("z default drive is a lead screw", str(s["axis"]["z"]["drive"]) == "leadscrew_t8_8")
	s["axis"]["x"]["drive"] = "belt_gt2_9"
	s["axis"]["y"]["drive"] = "leadscrew_t8_8"
	s["axis"]["y"]["motors"] = 3
	s = GantryLabSpec.resolve(s)
	_check("corexy couples Y to X drive", str(s["axis"]["y"]["drive"]) == "belt_gt2_9" and int(s["axis"]["y"]["motors"]) == 1)
	var c := GantryLabSpec.resolve({"kinematics": "nope", "volume": {"x_mm": 5.0, "z_mm": 99999.0}, "axis": {"x": {"microsteps": 7}}})
	_check("bad kinematics → bedslinger", str(c["kinematics"]) == "bedslinger")
	_check("volume clamped", float(c["volume"]["x_mm"]) == GantryLabSpec.MIN_AXIS_MM and float(c["volume"]["z_mm"]) == GantryLabSpec.MAX_AXIS_MM)
	_check("bad microsteps → 16", int(c["axis"]["x"]["microsteps"]) == 16)
	var dl := GantryLabSpec.resolve({"kinematics": "delta", "volume": {"x_mm": 200.0, "y_mm": 50.0}})
	_check("delta y follows x", float(dl["volume"]["y_mm"]) == 200.0)
	var g := GantryLabSpec.resolve({"electronics": {"board": "grbl_uno", "firmware": "klipper", "volts": 48}})
	_check("firmware forced to the board's", str(g["electronics"]["firmware"]) == "grbl" and int(g["electronics"]["volts"]) == 24)
	var k1 := GantryLabSpec.key_of(s)
	var k2 := GantryLabSpec.key_of(GantryLabSpec.resolve(JSON.parse_string(JSON.stringify(GantryLabSpec.to_json_safe(s)))))
	_check("key stable through JSON", k1 == k2)
	var s2 := s.duplicate(true)
	s2["volume"]["x_mm"] = 300.0
	_check("key moves with the volume", GantryLabSpec.key_of(s2) != k1)
	for a in GantryLabSpec.APPLICATIONS:
		var sp := GantryLabSpec.for_application(str(a["id"]))
		_check("application %s" % str(a["id"]), str(sp["kinematics"]) == str(a["kinematics"]) and str(sp["tool"]["id"]) == str(a["tool"]))
	_check("motor_axes delta is three towers", GantryLabSpec.motor_axes("delta").size() == 3 and str(GantryLabSpec.motor_axes("delta")[2]["label"]) == "Tower C")
	_check("describe", GantryLabSpec.describe(s).contains("CoreXY"))


func _test_kinematics() -> void:
	var belt := {"guide": "v_wheel", "drive": "belt_gt2_6", "motor": "nema17", "pulley_teeth": 20, "motors": 1, "microsteps": 16}
	_check("GT2 20T 16µ = 80 steps/mm", _approx(GantryLabKinematics.steps_per_mm(belt), 80.0, 1e-6))
	var t8 := belt.duplicate()
	t8["drive"] = "leadscrew_t8_8"
	_check("Tr8x8 16µ = 400 steps/mm", _approx(GantryLabKinematics.steps_per_mm(t8), 400.0, 1e-6))
	t8["drive"] = "leadscrew_t8_2"
	_check("Tr8x2 16µ = 1600 steps/mm", _approx(GantryLabKinematics.steps_per_mm(t8), 1600.0, 1e-6))
	var m09 := belt.duplicate()
	m09["motor"] = "nema17_09"
	_check("0.9° motor doubles steps", _approx(GantryLabKinematics.steps_per_mm(m09), 160.0, 1e-6))
	_check("resolution 12.5 µm", _approx(GantryLabKinematics.resolution_mm(belt) * 1000.0, 12.5, 1e-6))
	_check("max speed at 150 kHz = 1875 mm/s", _approx(GantryLabKinematics.max_speed_mm_s(belt, 150000.0), 1875.0, 1e-3))
	var cx := GantryLabSpec.default_spec("corexy")
	var mp := GantryLabKinematics.motor_positions(cx, Vector3(10.0, 4.0, 2.0))
	_check("corexy A = x+y, B = x−y", _approx(float(mp[0]["mm"]), 14.0, 1e-9) and _approx(float(mp[1]["mm"]), 6.0, 1e-9) and _approx(float(mp[2]["mm"]), 2.0, 1e-9))
	var hb := GantryLabSpec.default_spec("hbot")
	var mph := GantryLabKinematics.motor_positions(hb, Vector3(10.0, 4.0, 2.0))
	_check("hbot same equations", _approx(float(mph[0]["mm"]), 14.0, 1e-9) and _approx(float(mph[1]["mm"]), 6.0, 1e-9))
	var cz := GantryLabSpec.default_spec("corexz")
	var mpz := GantryLabKinematics.motor_positions(cz, Vector3(10.0, 4.0, 2.0))
	_check("corexz A = x+z, B = x−z, Y", _approx(float(mpz[0]["mm"]), 12.0, 1e-9) and _approx(float(mpz[1]["mm"]), 8.0, 1e-9) and _approx(float(mpz[2]["mm"]), 4.0, 1e-9))
	var cart := GantryLabSpec.default_spec("bedslinger")
	var mpc := GantryLabKinematics.motor_positions(cart, Vector3(10.0, 4.0, 2.0))
	_check("cartesian identity", _approx(float(mpc[0]["mm"]), 10.0, 1e-9) and _approx(float(mpc[1]["mm"]), 4.0, 1e-9))
	var mv := GantryLabKinematics.motor_velocity(cx, Vector3(1, 0, 0))
	_check("corexy pure X moves both motors at 1", _approx(float(mv[0]), 1.0, 1e-6) and _approx(float(mv[1]), 1.0, 1e-6))
	var mvd := GantryLabKinematics.motor_velocity(cx, Vector3(1, 1, 0).normalized())
	_check("corexy diagonal: one motor at √2, the other still", _approx(float(mvd[0]), sqrt(2.0), 1e-5) and _approx(float(mvd[1]), 0.0, 1e-5))
	var bl := GantryLabKinematics.belt_length_m("corexy", 300.0, 300.0, 300.0)
	_check("corexy two belts ~1.44 m each", int(bl["count"]) == 2 and _approx(float(bl["each_m"]), 1.44, 1e-6))


func _test_delta() -> void:
	var s := GantryLabSpec.default_spec("delta")
	_check("delta radius = tower − effector − carriage", _approx(GantryLabKinematics.delta_radius_mm(s), 88.0, 1e-9))
	var c := GantryLabKinematics.delta_carriages(s, Vector3.ZERO)
	var expect := sqrt(215.0 * 215.0 - 88.0 * 88.0)
	_check("centre carriages all equal at sqrt(L²−R²)", _approx(float(c[0]), expect, 1e-4) and _approx(float(c[1]), expect, 1e-4) and _approx(float(c[2]), expect, 1e-4))
	var p := Vector3(23.0, -17.0, 40.0)
	var cc := GantryLabKinematics.delta_carriages(s, p)
	var fwd := GantryLabKinematics.delta_forward(s, cc)
	_check("delta forward(inverse(p)) = p", fwd.distance_to(p) < 1e-3, str(fwd))
	var far := GantryLabKinematics.delta_carriages(s, Vector3(400.0, 0.0, 0.0))
	_check("unreachable → NaN", is_nan(float(far[0])) or is_nan(float(far[1])) or is_nan(float(far[2])))
	var r := GantryLabKinematics.delta_reach(s)
	_check("reach = L cos20° − R", _approx(float(r["reach_mm"]), 215.0 * cos(deg_to_rad(20.0)) - 88.0, 1e-6))
	_check("reach covers a 170 bed", float(r["reach_mm"]) > 85.0)
	var mv := GantryLabKinematics.motor_velocity(s, Vector3(0, 0, 1), Vector3.ZERO)
	_check("delta pure Z moves every tower at 1", _approx(float(mv[0]), 1.0, 1e-3) and _approx(float(mv[2]), 1.0, 1e-3))


func _test_physics() -> void:
	var belt := {"guide": "v_wheel", "drive": "belt_gt2_6", "motor": "nema17", "pulley_teeth": 20, "motors": 1, "microsteps": 16}
	# 0.4 N·m × 0.5 usable × 0.95 eff / (20·2/2π mm = 6.366 mm radius) = 29.8 N
	var f := GantryLabKinematics.drive_force_n(belt)
	_check("belt force from torque", _approx(f, 0.4 * 0.5 * 0.95 / (40.0 / TAU * 0.001), 1e-3), str(f))
	var t8 := belt.duplicate()
	t8["drive"] = "leadscrew_t8_8"
	var fs := GantryLabKinematics.drive_force_n(t8)
	_check("screw force = 2πTη/lead", _approx(fs, TAU * 0.2 * 0.4 / 0.008, 1e-3), str(fs))
	var acc := GantryLabKinematics.accel_capable_mm_s2(belt, 0.5, 0.0, 0.0)
	_check("accel = F/m", _approx(acc, f / 0.5 * 1000.0, 1e-3))
	_check("lifting halves it", GantryLabKinematics.accel_capable_mm_s2(belt, 0.5, 1.0, 0.0) < acc)
	var st := GantryLabKinematics.belt_stretch_mm(GantryLabParts.drive("belt_gt2_6"), 10.0, 1.0)
	_check("10 N on 1 m of GT2 6 mm stretches ~0.9 mm", _approx(st, 10.0 / 11000.0 * 1000.0, 1e-6))
	_check("9 mm belt stretches less", GantryLabKinematics.belt_stretch_mm(GantryLabParts.drive("belt_gt2_9"), 10.0, 1.0) < st)
	var nc := GantryLabKinematics.screw_critical_rpm(GantryLabParts.drive("leadscrew_t8_8"), 400.0)
	_check("Tr8 400 mm critical ≈ 184 rpm", _approx(nc, 4.76e6 * 6.2 / 160000.0, 1e-3), str(nc))
	_check("belt has no critical speed", not is_finite(GantryLabKinematics.screw_critical_rpm(GantryLabParts.drive("belt_gt2_6"), 400.0)))
	# δ = F L³ / 48 E I: 20 N over 0.5 m of 2020 (I = 0.72 cm⁴)
	var sag := GantryLabKinematics.beam_sag_m(20.0, 0.5, 0.72e-8)
	_check("sag by hand", _approx(sag, 20.0 * 0.125 / (48.0 * 68.9e9 * 0.72e-8), 1e-12), str(sag))
	_check("2060 sags less than 2020", GantryLabKinematics.beam_sag_m(20.0, 0.5, GantryLabParts.profile_i_m4("2060")) < sag * 0.1)
	var hz := GantryLabKinematics.natural_hz(GantryLabParts.drive("belt_gt2_6"), 0.35, 0.5)
	_check("ringing in the tens of Hz", hz > 20.0 and hz < 120.0, str(hz))


func _test_gcode() -> void:
	var g := "G21\nG90\nM104 S200\nG28\nG92 E0\nG1 Z0.2 F600\nG1 X10 Y0 E0.5 F1200\nG1 X10 Y10 E1.0\nG91\nG1 X-10 E0.5\nG90\nG0 X0 Y0 Z5\nG1 Z0.4\nG1 X10 E2.0 F600\n"
	var p := GantryLabGcode.parse(g)
	_check("parse ok", bool(p["ok"]))
	_check("hotend temp read", _approx(float(p["temps"]["hotend_c"]), 200.0, 1e-9))
	_check("extrusion 2.0 mm", _approx(float(p["extrusion_mm"]), 2.0, 1e-6), str(p["extrusion_mm"]))
	_check("relative move lands at x=0", (p["moves"][3] as Dictionary)["p1"] == Vector3(0, 10, 0.2) if p["moves"].size() > 4 else false)
	_check("bounds from extruding moves", (p["bounds_max"] as Vector3).x == 10.0 and (p["bounds_max"] as Vector3).y == 10.0)
	_check("two layers", int(p["layers"]) == 2)
	_check("reprap dialect", str(p["dialect"]) == "reprap")
	var feed_mm_s := float((p["moves"][2] as Dictionary)["feed_mm_s"])
	_check("F1200 → 20 mm/s", _approx(feed_mm_s, 20.0, 1e-6))
	_check("rapid flagged", bool((p["moves"][4] as Dictionary)["rapid"]))
	# Arcs: a full circle of radius 10 via I/J, and an R-form half circle.
	var arc := "G21 G90\nG0 X10 Y0\nG2 X10 Y0 I-10 J0 F600\nG0 X0 Y0\nG3 X20 Y0 R10\n"
	var pa := GantryLabGcode.parse(arc)
	var circ := 0.0
	var half := 0.0
	for mv in pa["moves"]:
		var m: Dictionary = mv
		if int(m["line"]) == 3:
			circ += (m["p0"] as Vector3).distance_to(m["p1"] as Vector3)
		elif int(m["line"]) == 5:
			half += (m["p0"] as Vector3).distance_to(m["p1"] as Vector3)
	_check("G2 full circle ≈ 2πr", _approx(circ, TAU * 10.0, 0.3), str(circ))
	_check("G3 R half circle ≈ πr", _approx(half, PI * 10.0, 0.2), str(half))
	var last: Dictionary = pa["moves"][pa["moves"].size() - 1]
	_check("arc lands on its end point", (last["p1"] as Vector3).distance_to(Vector3(20, 0, 0)) < 1e-4)
	var grbl := "$32=1\nG21 G90\nG0 X0 Y0\nM3 S500\nG1 X20 Y0 F3000\nG1 X20 Y20\nM5\nG0 X0 Y0\n"
	var pg := GantryLabGcode.parse(grbl)
	_check("grbl dialect, laser moves count as marking", str(pg["dialect"]) == "grbl" and float(pg["extrusion_mm"]) > 0.0)
	_check("laser S read", _approx(float(pg["laser_s_max"]), 500.0, 1e-9))
	var packed := "G1X5Y5F600\nG1X10\n"
	var pp := GantryLabGcode.parse(packed)
	_check("packed words parse", bool(pp["ok"]) and pp["moves"].size() == 2 and ((pp["moves"][1] as Dictionary)["p1"] as Vector3).x == 10.0)
	_check("empty text fails cleanly", not bool(GantryLabGcode.parse("; nothing\n")["ok"]))
	var tp := GantryLabGcode.to_toolpath(p)
	_check("to_toolpath shape", bool(tp["ok"]) and str(tp["kind"]) == "gcode" and (tp["points"] as PackedVector3Array).size() == (tp["extruding"] as PackedInt32Array).size() and int(tp["point_count"]) > 2)
	_check("to_toolpath carries extrusion", _approx(float(tp["extrusion_mm"]), 2.0, 1e-6))


func _test_motion() -> void:
	# One 100 mm move at 50 mm/s, accel 1000: ta = 0.05 s, da = 1.25 mm each
	# end, cruise 97.5 mm / 50 = 1.95 s → 2.05 s total.
	var p := GantryLabGcode.parse("G21 G90\nG1 X100 F3000\n")
	var pl := GantryLabMotion.plan(p, {"max_feed_mm_s": 200.0, "accel_mm_s2": 1000.0, "junction_mm_s": 8.0})
	_check("plan ok", bool(pl["ok"]) and int(pl["n"]) == 1)
	_check("trapezoid time by hand", _approx(float(pl["total_s"]), 2.05, 1e-4), str(pl["total_s"]))
	var mid := GantryLabMotion.sample(pl, 1.025)
	_check("mid-move at cruise speed, mid position", _approx(float(mid["v"]), 50.0, 1e-6) and _approx((mid["pos"] as Vector3).x, 50.0, 0.01), str(mid))
	var end := GantryLabMotion.sample(pl, 99.0)
	_check("past the end clamps to the end", _approx((end["pos"] as Vector3).x, 100.0, 1e-4))
	# Too short to reach feed: 2 mm at 50 mm/s, accel 1000 → triangle, v_peak = sqrt(2000) ≈ 44.7
	var p2 := GantryLabGcode.parse("G21 G90\nG1 X2 F3000\n")
	var pl2 := GantryLabMotion.plan(p2, {"max_feed_mm_s": 200.0, "accel_mm_s2": 1000.0, "junction_mm_s": 8.0})
	_check("short move is a triangle", _approx(float((pl2["v_peak"] as PackedFloat32Array)[0]), sqrt(2000.0), 1e-3) and float(pl2["accel_limited_share"]) == 1.0)
	# A corner: 90° turn slows to the jerk speed (8 / √2 ≈ 5.66 mm/s).
	var p3 := GantryLabGcode.parse("G21 G90\nG1 X50 F3000\nG1 Y50\n")
	var pl3 := GantryLabMotion.plan(p3, {"max_feed_mm_s": 200.0, "accel_mm_s2": 1000.0, "junction_mm_s": 8.0})
	_check("corner speed = jerk/|Δd|", _approx(float((pl3["v_out"] as PackedFloat32Array)[0]), 8.0 / sqrt(2.0), 1e-4), str((pl3["v_out"] as PackedFloat32Array)[0]))
	# A straight continuation keeps full speed.
	var p4 := GantryLabGcode.parse("G21 G90\nG1 X50 F3000\nG1 X100\n")
	var pl4 := GantryLabMotion.plan(p4, {"max_feed_mm_s": 200.0, "accel_mm_s2": 1000.0, "junction_mm_s": 8.0})
	_check("straight-through junction at feed", _approx(float((pl4["v_out"] as PackedFloat32Array)[0]), 50.0, 1e-4))
	# Sampling is monotone in time.
	var mono := true
	var last_x := -1.0
	for i in 60:
		var sm := GantryLabMotion.sample(pl4, float(pl4["total_s"]) * float(i) / 59.0)
		if (sm["pos"] as Vector3).x < last_x - 1e-6:
			mono = false
		last_x = (sm["pos"] as Vector3).x
	_check("sample monotone", mono)
	# Step-rate peak with a corexy spec: 80 steps/mm, 50 mm/s along X → 4000 Hz on A.
	var cx := GantryLabSpec.default_spec("corexy")
	var d := GantryLabDesign.solve(cx)
	var pl5 := GantryLabMotion.plan(p, d["limits"])
	_check("peak step rate = v·spm", _approx(float(pl5["peak_step_hz"]), 50.0 * 80.0, 1.0), str(pl5["peak_step_hz"]))
	_check("fmt_duration", GantryLabMotion.fmt_duration(125.0) == "2 min 05 s")


func _test_layouts() -> void:
	for kin in GantryLabSpec.KINEMATICS:
		var s := GantryLabSpec.default_spec(kin)
		var lay := GantryLabFrame.layout(s)
		var beams := GantryLabFrame.all_beams(lay)
		_check("%s has beams and assemblies" % kin, beams.size() >= 3 and (lay["assemblies"] as Dictionary).size() >= 3)
		var po := GantryLabFrame.pose(s, lay, Vector3(100.0, 50.0, 20.0))
		_check("%s pose names every assembly" % kin, po.size() == (lay["assemblies"] as Dictionary).size())
		var dims: Vector3 = lay["dims"]
		_check("%s dims positive" % kin, dims.x > 0.2 and dims.y > 0.2 and dims.z > 0.2)
		var belts := GantryLabFrame.belt_routes(s, lay, po)
		_check("%s belts drawn" % kin, belts.size() >= 1 or kin == "router")
	# The tool over the work origin: a cartesian carriage at x = 0 sits at
	# the bed's left edge, at x = vx at its right edge.
	var s := GantryLabSpec.default_spec("cartesian_xy")
	var lay := GantryLabFrame.layout(s)
	var o0 := GantryLabFrame.assembly_origin(lay, GantryLabFrame.pose(s, lay, Vector3.ZERO), "XCarriage")
	var o1 := GantryLabFrame.assembly_origin(lay, GantryLabFrame.pose(s, lay, Vector3(220.0, 220.0, 0.0)), "XCarriage")
	_check("carriage travels the X volume", _approx(o1.x - o0.x, 0.22, 1e-6) and _approx(o1.z - o0.z, 0.22, 1e-6))
	# The carriage's parts sit where the tool is at x = 0; the origin is the
	# nozzle at the bed's front-left.
	_check("origin at the bed's front-left", _approx((lay["origin"] as Vector3).x, -0.11, 1e-6) and _approx(o0.x, 0.0, 1e-6))
	var bs := GantryLabSpec.default_spec("bedslinger")
	var blay := GantryLabFrame.layout(bs)
	var b0 := GantryLabFrame.assembly_origin(blay, GantryLabFrame.pose(bs, blay, Vector3.ZERO), "Bed")
	var b1 := GantryLabFrame.assembly_origin(blay, GantryLabFrame.pose(bs, blay, Vector3(0, 220.0, 0)), "Bed")
	_check("bed-slinger bed moves −Y by the Y command", _approx(b0.z - b1.z, 0.22, 1e-6))
	var dl := GantryLabSpec.default_spec("delta")
	var dlay := GantryLabFrame.layout(dl)
	var arms := GantryLabFrame.delta_arms(dlay, GantryLabFrame.pose(dl, dlay, Vector3(10, 0, 30)))
	_check("six delta arms", arms.size() == 6)
	var l0 := ((arms[0] as Array)[0] as Vector3).distance_to((arms[0] as Array)[1] as Vector3)
	_check("arm drawn at its length", _approx(l0, 0.215, 0.02), str(l0))


func _test_presets_and_bom() -> void:
	var ids: Dictionary = {}
	for p in GantryLabPresets.builtins():
		var d := GantryLabDesign.solve(p["spec"])
		var errors := 0
		for c in d["checks"]:
			if str(c["level"]) == "error":
				errors += 1
				print("    %s: %s" % [str(p["id"]), str(c["text"])])
		_check("preset %s solves clean" % str(p["id"]), errors == 0)
		ids[str(p["id"])] = true
		var bom: Dictionary = d["bom"]
		_check("preset %s costs and weighs" % str(p["id"]), float(bom["usd"]) > 100.0 and float(bom["kg"]) > 1.0 and int(bom["motors"]) >= 3)
	_check("14 presets, unique ids", ids.size() == 14)
	var s := GantryLabSpec.default_spec("corexy")
	var d := GantryLabDesign.solve(s)
	_check("solve cached", GantryLabDesign.solve(s) == d)
	var bom: Dictionary = d["bom"]
	var frame_rows := 0
	for r in bom["rows"]:
		if str(r["cat"]) == "Frame":
			frame_rows += 1
	_check("cut list and stock", (bom["cut_list"] as Array).size() >= 3 and int(bom["stock"]["pieces"]) >= 2 and frame_rows >= 3)
	_check("corexy BOM has two belt loops and idlers", bom["belt_m"] > 2.0 and str(bom["belt_kind"]).begins_with("GT2"))
	_check("three motors + extruder", int(bom["motors"]) == 4 + int(s["axis"]["z"]["motors"]) - 1)
	var m: Array = d["motors"]
	_check("motor rows A, B, Z", m.size() == 3 and str(m[0]["label"]).begins_with("Motor A"))
	_check("packed spec", str(GantryLabDesign.packed_spec(d)["form"]) == "bundle" and float(GantryLabDesign.packed_spec(d)["mass_kg"]) > 2.0)
	var gp := GantryLabDesign.graph_preset(s, d)
	_check("graph preset is a cartesian_machine fdm printer", str(gp["specs"]["role"]) == "cartesian_machine" and str(gp["specs"]["machine_role"]) == "fdm_printer" and str(gp["specs"]["model_id"]) == "gantry_machine")
	_check("filament input", str((gp["specs"]["inputs"] as Array)[0]["kind"]) == "filament")
	var rt := GantryLabDesign.solve(GantryLabSpec.for_application("wood"))
	_check("router preset is a cnc_router with no feedstock", str(rt["graph_preset"]["specs"]["machine_role"]) == "cnc_router" and (rt["graph_preset"]["specs"]["inputs"] as Array).is_empty())
	# A bad design trips the checks: an 8-bit board asked for 300 mm/s on 1/32 steps.
	var bad := GantryLabSpec.default_spec("corexy")
	bad["electronics"]["board"] = "ramps_14"
	bad["electronics"]["firmware"] = "marlin"
	bad["electronics"]["max_feed_mm_s"] = 300.0
	bad["axis"]["x"]["microsteps"] = 32
	var bd := GantryLabDesign.solve(bad)
	var has_err := false
	for c in bd["checks"]:
		if str(c["level"]) == "error" and str(c["text"]).contains("steps/s"):
			has_err = true
	_check("8-bit board at 300 mm/s is an error", has_err)
	var tiny := GantryLabSpec.default_spec("delta")
	tiny["delta"]["arm_mm"] = 120.0
	var td := GantryLabDesign.solve(tiny)
	var reach_err := false
	for c in td["checks"]:
		if str(c["level"]) == "error" and str(c["text"]).contains("reach"):
			reach_err = true
	_check("short delta arms are an error", reach_err)


func _test_exports_and_samples() -> void:
	var d := GantryLabDesign.solve(GantryLabPresets.builtin("corexy_300")["spec"])
	var kc := GantryLabExport.klipper_cfg(d)
	_check("klipper corexy", kc.contains("kinematics: corexy") and kc.contains("rotation_distance: 40.000") and kc.contains("[input_shaper]"))
	var mh := GantryLabExport.marlin_h(d)
	_check("marlin COREXY + steps", mh.contains("#define COREXY") and mh.contains("80.00"))
	var dd := GantryLabDesign.solve(GantryLabPresets.builtin("kossel_mini")["spec"])
	_check("klipper delta", GantryLabExport.klipper_cfg(dd).contains("kinematics: delta") and GantryLabExport.klipper_cfg(dd).contains("arm_length: 215.0"))
	var rd := GantryLabDesign.solve(GantryLabPresets.builtin("lead_750")["spec"])
	var gs := GantryLabExport.grbl_settings(rd)
	_check("grbl steps/mm for Tr8x8 NEMA23 = 400", gs.contains("$100=400.000"))
	_check("design json parses", JSON.parse_string(GantryLabExport.design_json(d)) is Dictionary)
	var tmp := OS.get_temp_dir().path_join("gantrylab_selftest_%d" % Time.get_ticks_usec())
	var w := GantryLabExport.write_all(d, tmp)
	_check("write_all six files", bool(w["ok"]) and (w["files"] as Array).size() == 6)
	for f in w["files"]:
		DirAccess.remove_absolute(str(f))
	DirAccess.remove_absolute(tmp)
	_check("safe_name", GantryLabExport.safe_name("CoreXY 300 (Voron-class)") == "corexy_300_voron_class")
	# Every sample parses and plans on its own machine.
	var checked := 0
	for p in GantryLabPresets.builtins():
		var s: Dictionary = p["spec"]
		var ds := GantryLabDesign.solve(s)
		for smp in GantryLabSamples.list(s):
			var txt := GantryLabSamples.text(s, str(smp["id"]))
			var parse := GantryLabGcode.parse(txt)
			var pl := GantryLabMotion.plan(parse, ds["limits"])
			if not (bool(parse["ok"]) and bool(pl["ok"]) and float(pl["total_s"]) > 1.0):
				print("    sample %s on %s failed: %s" % [str(smp["id"]), str(p["id"]), str(parse.get("error", ""))])
				_check("sample %s on %s" % [str(smp["id"]), str(p["id"])], false)
			checked += 1
	_check("samples checked", checked >= 30, str(checked))
	var cube := GantryLabGcode.parse(GantryLabSamples.text(GantryLabSpec.default_spec("bedslinger"), "cube"))
	_check("cube is 20 mm and extrudes", _approx(((cube["bounds_max"] as Vector3) - (cube["bounds_min"] as Vector3)).x, 20.0, 0.01) and float(cube["extrusion_mm"]) > 100.0 and int(cube["layers"]) == 100)
	var pocket := GantryLabGcode.parse(GantryLabSamples.text(GantryLabSpec.for_application("wood"), "pocket"))
	_check("pocket has arcs and rapids and no extrusion", bool(pocket["ok"]) and float(pocket["total_rapid_mm"]) > 0.0 and float(pocket["extrusion_mm"]) == 0.0 and str(pocket["dialect"]) == "grbl")
	_check("library round trip", GantryLabPresets.load_library("user://no_such_gantry_library.json").is_empty())


func _test_builder() -> void:
	for kin in GantryLabSpec.KINEMATICS:
		var s := GantryLabSpec.default_spec(kin)
		var n := GantryLabBuilder.build_node(s, "M", {"record": true})
		var mesh := n.get_node_or_null("Mesh") as MeshInstance3D
		_check("%s builds a frame mesh" % kin, mesh != null and mesh.mesh != null and mesh.mesh.get_surface_count() >= 2)
		_check("%s has drivers" % kin, n.get_node_or_null("XDrive") != null and n.get_node_or_null("YDrive") != null and n.get_node_or_null("ZDrive") != null)
		var asm_count := 0
		for name in (n as GantryLabBuilder).layout()["assemblies"]:
			if n.find_child(str(name), true, false) != null:
				asm_count += 1
		_check("%s has every assembly node" % kin, asm_count == ((n as GantryLabBuilder).layout()["assemblies"] as Dictionary).size())
		n.free()
	var cx := GantryLabSpec.default_spec("corexy")
	var b := GantryLabBuilder.build_node(cx, "M", {"record": true}) as GantryLabBuilder
	var car := b.get_node("XBeam/XCarriage") as Node3D
	var x0 := car.position.x
	b.set_tool_mm(Vector3(50.0, 0.0, 0.0))
	_check("set_tool_mm moves the carriage 50 mm", _approx(car.position.x - x0, 0.05, 1e-6))
	b.set_drivers_mm(Vector3(80.0, 30.0, 10.0))
	b._process(0.016)
	_check("drivers drive the kinematics", _approx(car.position.x - x0, 0.08, 1e-6) and _approx(b.tool_mm().y, 30.0, 1e-6))
	var belts := b.get_node("Belts") as MeshInstance3D
	_check("belts drawn", belts.mesh != null and belts.mesh.get_surface_count() >= 2)  # two CoreXY loops (+ the Bowden tube, the filament)
	var hit := GantryLabBuilder.pick(b, Vector3(0.0, 2.0, 0.0), Vector3(0, -1, 0))
	_check("a ray from above hits something", not hit.is_empty())
	var pts := PackedVector3Array([Vector3(10, 10, 0.2), Vector3(50, 10, 0.2), Vector3(50, 50, 0.2), Vector3(10, 50, 0.2)])
	b.set_toolpath_preview(pts, PackedInt32Array([0, 1, 1, 1]), 0.4, Color.WHITE)
	var beads := b.bead_parent().get_node_or_null("Beads") as MultiMeshInstance3D
	_check("beads under the bed node", beads != null and b.bead_parent().name == "Bed" and beads.multimesh.instance_count == 3)
	b.set_preview_progress(0.67)
	_check("progress reveals beads", beads.multimesh.visible_instance_count == 2)
	var size: Vector3 = b.get_meta("size_m")
	_check("size meta", size.x > 0.3 and size.y > 0.3)
	b.free()
	var dl := GantryLabBuilder.build_node(GantryLabSpec.default_spec("delta"), "D", {}) as GantryLabBuilder
	dl.set_tool_mm(Vector3(20.0, 0.0, 30.0))
	var ca := dl.get_node("CarriageA") as Node3D
	var cb := dl.get_node("CarriageB") as Node3D
	_check("delta carriages differ off-centre", absf(ca.position.y - cb.position.y) > 1e-4)
	dl.free()
