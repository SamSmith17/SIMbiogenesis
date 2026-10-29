extends SceneTree

## Pelton wheel designer self-test (offline). Run --import first.
##   Godot --headless --path . --script core/peltonlab/peltonlab_selftest.gd
## The cup STL read into the cup frame and seated on a wheel (proper
## transforms, open face to the jet, tip on the tip circle), the runner's
## circles and design rules by hand, rpm = 2·0.46·v/PCD (bigger wheel, slower,
## same power), the crowding limit, the rotor / hub / bolt-pattern geometry,
## the drives' ratios and belt length, the generator curve, the housing and
## nozzles, the hand-off to HydroSource (the graph's power == the designer's),
## every built-in clean, the builder's nodes and spin, ports, the cut files,
## the packed spec and the preset.

const EXPECTED_CHECKS := 95

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
	PeltonLabDesign.clear_cache()
	_test_cup()
	_test_seating()
	_test_runner_rules()
	_test_speed_and_power()
	_test_rotor()
	_test_drive()
	_test_housing_and_jets()
	_test_hydro_handoff()
	_test_presets()
	_test_builder()
	_test_ports_cam_pack()
	_test_spec()
	if _n != EXPECTED_CHECKS:
		_fails += 1
		print("  FAIL: ran %d checks, expected %d (a runtime error may have aborted a test)" % [_n, EXPECTED_CHECKS])
	print("PELTONLAB SELFTEST %s  (%d checks, %d failed)" % ["PASS" if _fails == 0 else "FAIL", _n, _fails])
	quit(0 if _fails == 0 else 1)


func _test_cup() -> void:
	var m := PeltonLabCup.mesh()
	_check(PeltonLabCup.from_file(), "the cup mesh is read from the shipped STL")
	var arr := m.surface_get_arrays(0)
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var nrm: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	_check(v.size() == 11042 * 3, "every facet of the STL (11042) is in the mesh")
	var box := AABB(v[0], Vector3.ZERO)
	for p in v:
		box = box.expand(p)
	_check(_near(box.size.x, 0.07904, 0.0002), "the cup is 79.04 mm across (%.5f)" % box.size.x)
	_check(_near(box.position.z, (4.61 - 40.0) * 0.001, 0.0002), "the tip sits 35.4 mm outward of the pitch point")
	_check(_near(box.end.z, (114.81 - 40.0) * 0.001, 0.0002), "the root tab ends 74.8 mm inward")
	_check(_near(box.get_center().x, 0.0, 0.0002), "the splitter is the cup frame's x = 0")
	# Winding: Godot's front face is clockwise from outside, so (c−a)×(b−a)
	# points along the stored outward normal on (nearly) every facet.
	var agree := 0
	for f in range(0, v.size(), 3):
		var g := (v[f + 2] - v[f]).cross(v[f + 1] - v[f])
		if g.dot(nrm[f] + nrm[f + 1] + nrm[f + 2]) > 0.0:
			agree += 1
	_check(float(agree) / float(v.size() / 3) > 0.97, "facets face outward in Godot's winding (%d of %d)" % [agree, v.size() / 3])
	_check(_near(PeltonLabCup.tab_depth_mm(77.0), 24.3, 0.05) and _near(PeltonLabCup.tab_depth_mm(114.81), 10.6, 0.05),
		"the tab tapers 24.3 → 10.6 mm")
	_check(_near(PeltonLabCup.mass_kg(1.0, "alu_cast"), 63122e-9 * 2700.0, 1e-4), "cup mass = volume × density")
	_check(_near(PeltonLabCup.mass_kg(2.0, "alu_cast"), 8.0 * PeltonLabCup.mass_kg(1.0, "alu_cast"), 1e-4), "mass scales with the cube")


func _test_seating() -> void:
	var th := 0.7
	var xf := PeltonLabCup.cup_transform(th, 0.14, 1.0)
	_check(xf.basis.determinant() > 0.0, "a seated cup is a proper rotation (no mirror)")
	var tip := xf * Vector3(0.0, 0.0, (4.61 - 40.0) * 0.001)
	_check(_near(Vector2(tip.x, tip.z).length(), 0.14 + 0.03539, 1e-5) and _near(tip.y, 0.0, 1e-6),
		"the tip lands on the tip circle, in the wheel's plane")
	_check(_near(Vector2(xf.origin.x, xf.origin.z).length(), 0.14, 1e-6), "the pitch point is on the pitch circle")
	var open_dir := xf.basis * Vector3(0, 1, 0)
	_check(open_dir.normalized().dot(PeltonLabCup.tangent(th)) < -0.99, "the open face faces back toward the jet (−t)")
	_check(absf((xf.basis * Vector3.RIGHT).normalized().dot(Vector3.UP)) > 0.99, "the cup's width runs along the shaft")
	var k2 := PeltonLabCup.cup_transform(th, 0.14, 0.5)
	_check(_near((k2.basis * Vector3.RIGHT).length(), 0.5, 1e-6), "the cup scales whole")


func _test_runner_rules() -> void:
	var d := PeltonLabDesign.solve(PeltonLabPresets.classic_spec())
	var rn: Dictionary = d["runner"]
	_check(_near(float(rn["tip_r_mm"]), 175.5, 1e-6), "tip radius = overall / 2")
	_check(_near(float(rn["pitch_r_mm"]), 175.5 - 35.39, 1e-3), "pitch radius = tip − 35.39 mm × k")
	_check(_near(float(rn["root_r_mm"]), float(rn["pitch_r_mm"]) - 74.81, 1e-3), "root radius = pitch − 74.81 mm × k")
	var r: Dictionary = d["rules"]
	_check(_near(float(r["m"]), float(rn["pcd_mm"]) / 22.0, 1e-6), "m = PCD / d")
	_check(_near(float(r["z_opt"]), 15.0 + 0.5 * float(r["m"]), 1e-6), "Z = 15 + m/2")
	# Crowding: the tabs touch where 2πr/Z falls under their depth + 1 mm.
	var lim_bowl := int(floor(TAU * float(rn["bowl_root_r_mm"]) / (24.3 + 1.0)))
	var lim_root := int(floor(TAU * float(rn["root_r_mm"]) / (10.6 + 1.0)))
	_check(int(r["max_cups"]) == mini(lim_bowl, lim_root), "max cups by hand (%d)" % int(r["max_cups"]))
	_check(_near(float(r["factor"]), 1.0, 1e-6), "the classic wheel takes no penalty")
	var crowded := PeltonLabPresets.classic_spec()
	crowded["runner"]["cups"] = int(r["max_cups"]) + 3
	_check(PeltonLabDesign.worst_level(PeltonLabDesign.solve(crowded)) == "error", "too many cups is an error")
	var wide_jet := PeltonLabPresets.classic_spec()
	wide_jet["jets"]["d_mm"] = 40.0
	var dw := PeltonLabDesign.solve(wide_jet)
	_check(float(dw["rules"]["f_b"]) < 0.8, "a jet too wide for the cups costs efficiency (%.2f)" % float(dw["rules"]["f_b"]))
	var few := PeltonLabPresets.classic_spec()
	few["runner"]["cups"] = 12
	_check(float(PeltonLabDesign.solve(few)["rules"]["f_z"]) < 0.9, "too few cups lets jet through (penalty)")


func _test_speed_and_power() -> void:
	var s := PeltonLabPresets.classic_spec()
	var d := PeltonLabDesign.solve(s)
	var p: Dictionary = d["perf"]
	var pcd := float(d["runner"]["pcd_mm"]) * 0.001
	_check(_near(float(p["rpm"]), 60.0 * 2.0 * 0.46 * float(p["v_jet_ms"]) / (TAU * pcd), 0.01), "rpm = 60·2·0.46·v / (2π·PCD)")
	_check(_near(float(p["rpm_runaway"]), PeltonPhysics.rpm_at_ratio(PeltonPhysics.jet_velocity_ms(15.0), pcd, 0.92), 0.01),
		"runaway = twice the speed ratio at the gross head")
	var big := s.duplicate(true)
	big["runner"]["overall_d_mm"] = 2.0 * float(s["runner"]["overall_d_mm"]) - 2.0 * 35.39
	big["runner"]["cups"] = int(round(15.0 + 0.5 * 2.0 * pcd * 1000.0 / 22.0))
	var d2 := PeltonLabDesign.solve(big)
	_check(_near(float(d2["runner"]["pcd_mm"]), 2.0 * pcd * 1000.0, 0.01), "the bigger wheel has twice the PCD")
	_check(_near(float(d2["perf"]["rpm"]), 0.5 * float(p["rpm"]), 0.05), "twice the PCD turns half as fast")
	_check(_near(float(d2["perf"]["p_shaft_w"]), float(p["p_shaft_w"]), 0.5), "…with the same shaft power")
	_check(_near(float(d2["perf"]["torque_nm"]), 2.0 * float(p["torque_nm"]), 0.05), "…and twice the torque")
	_check(_near(float(p["p_shaft_w"]), float(p["p_hyd_w"]) * float(p["eta_runner"]), 1e-3), "shaft = water × runner η")
	_check(_near(float(p["gen_rpm"]), float(p["rpm"]) * 160.0 / 100.0, 0.01), "generator rpm = wheel × D1/D2")
	var g := PeltonLabParts.generator("pma400")
	_check(_near(PeltonLabDesign.generator_eff_at(g, 800.0), float(g["eff"]), 1e-6)
		and PeltonLabDesign.generator_eff_at(g, 400.0) < float(g["eff"])
		and PeltonLabDesign.generator_eff_at(g, 1600.0) < float(g["eff"]), "the generator peaks at its rated speed")
	_check(_near(float(p["v_oc"]), 0.045 * float(p["gen_rpm"]), 1e-6), "open-circuit volts = V/rpm × rpm")
	var f := float(p["f_stall_n"])
	_check(_near(f, 1000.0 * float(p["q_lps"]) * 0.001 * float(p["v_jet_ms"]) * 1.966, 0.01), "stall force = ρQv(1 + cos 15°)")


func _test_rotor() -> void:
	var d := PeltonLabDesign.solve(PeltonLabPresets.classic_spec())
	var ro: Dictionary = d["rotor"]
	var rn: Dictionary = d["runner"]
	_check(_near(float(ro["disc_r_mm"]), PeltonLabCup.radius_at(80.0, float(rn["pitch_r_mm"]), 1.0), 1e-3),
		"the auto disc runs to 3 mm under the bowls")
	var outer := float((rn["bolt_radii_mm"] as Array).max())
	_check(float(ro["disc_r_mm"]) >= outer + 1.5 * 6.6 and float(ro["disc_r_mm"]) <= float(rn["bowl_root_r_mm"]),
		"…covering the cup bolts and clear of the bowls")
	_check(_near(float(ro["gap_mm"]), 34.0, 1e-6), "the discs sit a tab (34 mm) apart")
	var pcd_r := float(ro["bolt_pcd_mm"]) * 0.5
	_check(pcd_r - 4.5 * 0.75 > float(ro["boss_d_mm"]) * 0.5 and pcd_r + 4.5 * 0.75 < float(ro["spacer_r_mm"]),
		"the auto bolt circle lies between the boss and the spacer's rim")
	_check((d["runner"]["cup_bolts"] as Array).size() == int(rn["cups"]) * 2, "two bolts per cup")
	var tiny := PeltonLabPresets.classic_spec()
	tiny["rotor"]["disc_d_mm"] = 150.0
	_check(PeltonLabDesign.worst_level(PeltonLabDesign.solve(tiny)) == "error", "discs short of the bolts are an error")
	var weak := PeltonLabPresets.classic_spec()
	weak["hub"]["shaft_d_mm"] = 12.0
	weak["site"]["gross_head_m"] = 60.0
	var dw := PeltonLabDesign.solve(weak)
	_check(float(dw["strength"]["shaft_mpa"]) > PeltonLabParts.SHAFT_TAU_ALLOW_MPA, "a 12 mm shaft at 60 m is over-stressed")
	var ds := float(dw["shaft"]["d_mm"]) * 0.001
	_check(float(dw["strength"]["shaft_mpa"]) >= 16.0 * float(dw["perf"]["t_stall_nm"]) / (PI * ds * ds * ds) / 1e6 - 1e-6,
		"shaft stress ≥ the torsion alone (16T/πd³)")
	var fc := float(d["strength"]["f_cup_runaway_n"])
	var w := float(d["perf"]["rpm_runaway"]) * TAU / 60.0
	_check(_near(fc, float(rn["cup_mass_kg"]) * w * w * float(rn["cg_r_mm"]) * 0.001, 1e-3), "cup pull at runaway = mω²r")


func _test_drive() -> void:
	var s := PeltonLabPresets.classic_spec()
	var d := PeltonLabDesign.solve(s)
	var dv: Dictionary = d["drive"]
	_check(_near(float(dv["ratio"]), 1.6, 1e-6), "V-belt ratio = D1 / D2")
	var c := float(dv["centre_mm"])
	_check(_near(float(dv["belt_len_mm"]), 2.0 * c + PI * 130.0 + 3600.0 / (4.0 * c), 1e-3), "open-belt length formula")
	var t := s.duplicate(true)
	t["drive"]["type"] = "timing"
	var dt := PeltonLabDesign.solve(t)
	_check(_near(float(dt["drive"]["ratio"]), 40.0 / 24.0, 1e-6), "timing ratio = z1 / z2")
	var g := s.duplicate(true)
	g["drive"]["type"] = "gear"
	var dg := PeltonLabDesign.solve(g)
	_check(_near(float(dg["drive"]["centre_mm"]), 2.0 * 64.0 * 0.5, 1e-6) and bool(dg["drive"]["reverses"]),
		"gears mesh at m(z1+z2)/2 and reverse")
	var dd := s.duplicate(true)
	dd["drive"]["type"] = "direct"
	var ddd := PeltonLabDesign.solve(dd)
	_check(_near(float(ddd["drive"]["ratio"]), 1.0, 1e-9) and (ddd["generator"]["axis"] as Vector3).y == 0.0,
		"direct drive: 1 : 1 on the shaft's axis")
	_check(float(ddd["drive"]["coupler"]["torque_nm"]) >= PeltonLabDesign.stall_torque_nm(ddd), "the jaw coupler takes the stall torque")
	var loop := PeltonLabBuilder.belt_loop(Vector2.ZERO, 0.08, Vector2(0.2, 0.0), 0.05)
	var ok := true
	for i in loop.size():
		var q: Vector2 = loop[i]
		var da := absf(q.length() - 0.08)
		var db := absf((q - Vector2(0.2, 0.0)).length() - 0.05)
		ok = ok and minf(da, db) < 1e-5
	_check(ok, "the belt loop's points lie on the two pulleys")
	var st := s.duplicate(true)
	st["drive"]["layout"] = "straddle"
	_check((PeltonLabDesign.solve(st)["shaft"]["bearings_x_mm"] as Array)[1] < 0.0, "straddle puts a bearing each side")


func _test_housing_and_jets() -> void:
	var d := PeltonLabDesign.solve(PeltonLabPresets.classic_spec())
	var h: Dictionary = d["housing"]
	_check(float(h["hy_mm"]) > float(d["runner"]["tip_r_mm"]) and float(h["hz_mm"]) > float(d["runner"]["tip_r_mm"]),
		"the auto housing clears the cup tips")
	_check(_near(float(h["axial_mm"]), 3.0 * 79.04, 1e-3), "…3 × the cup width across the shaft")
	var j: Dictionary = d["jets"][0]
	_check(bool(j["inside"]), "the nozzle's mouth is inside the housing")
	var hit: Vector3 = j["hit"]
	_check(_near(Vector2(hit.y, hit.z).length(), float(d["runner"]["pitch_r_mm"]) * 0.001, 1e-6) and hit.y < 0.0,
		"the first jet meets the pitch circle under a horizontal wheel")
	_check(_near((j["dir"] as Vector3).dot(hit.normalized()), 0.0, 1e-6), "…tangent to it")
	var wp: Vector3 = j["wall_pt"]
	_check(_near(absf(wp.z), float(h["hz_mm"]) * 0.001, 1e-6) or _near(absf(wp.y), float(h["hy_mm"]) * 0.001, 1e-6),
		"the nozzle leaves through a wall")
	var v := PeltonLabPresets.vertical_spec()
	var dv := PeltonLabDesign.solve(v)
	_check((dv["jets"] as Array).size() == 4, "four jets on the vertical wheel")
	var spread := true
	for i in 4:
		spread = spread and _near(float(dv["jets"][i]["deg"]), 90.0 * float(i), 1e-6)
	_check(spread, "…evenly round it")
	_check(str(dv["spin_axis"]) == "y" and ((dv["model_xf"] as Transform3D).basis * Vector3.RIGHT).is_equal_approx(Vector3.UP),
		"a vertical shaft points up in the model")
	_check(_near((dv["aabb"] as AABB).position.y, 0.0, 1e-4) and _near((d["aabb"] as AABB).position.y, 0.0, 1e-4),
		"both stand on y = 0")


func _test_hydro_handoff() -> void:
	# The graph's power from the patched specs == the designer's electrical W.
	var d := PeltonLabDesign.solve(PeltonLabPresets.classic_spec())
	var pre := ComponentPresets.designed_pelton_preset(d["spec"])
	var sp: Dictionary = pre["specs"]
	_check(str(sp["turbine_kind"]) == "designed_pelton" and not (sp["pelton_spec"] as Dictionary).is_empty(),
		"the designed preset carries its wheel")
	_check(_near(float(sp["runner_pcd_m"]), float(d["runner"]["pcd_mm"]) * 0.001, 1e-9), "…and its PCD")
	var kw := HydroSource.power_kw_from_graph_specs(sp, 6)
	_check(_near(kw * 1000.0, float(d["perf"]["p_elec_w"]), maxf(0.01 * float(d["perf"]["p_elec_w"]), 0.5)),
		"HydroSource makes the designer's power (%.1f W vs %.1f W)" % [kw * 1000.0, float(d["perf"]["p_elec_w"])])
	var q := HydroSource.operating_flow_lps_from_graph_specs(sp, 6)
	_check(_near(q, float(d["perf"]["q_lps"]), 1e-3), "…and its flow")
	_check(HydroSource.kind_meta("designed_pelton").get("model_id", "") == PeltonLabBuilder.MODEL_ID, "the kind wears the designed model")
	var reach := HydroReach.new()
	reach.configure_siphon(sp)
	_check(_near(reach.runner_pcd_m, float(d["runner"]["pcd_mm"]) * 0.001, 1e-9), "the hydro reach reads the designed PCD")


func _test_presets() -> void:
	var clean := true
	var names := []
	for b in PeltonLabPresets.builtins():
		var dd := PeltonLabDesign.solve(b["spec"])
		if PeltonLabDesign.worst_level(dd) == "error":
			clean = false
			names.append(str(b["id"]))
	_check(clean, "every built-in solves without an error %s" % str(names))
	_check(PeltonLabPresets.builtins().size() == 5, "five built-in wheels")


func _test_builder() -> void:
	var d := PeltonLabDesign.solve(PeltonLabPresets.classic_spec())
	var b := PeltonLabBuilder.build_from_design(d) as PeltonLabBuilder
	var runner := b.get_node_or_null("Machine/Runner") as Node3D
	_check(runner != null and b.get_node_or_null("Machine/ShaftSpin") != null and b.get_node_or_null("Machine/GenSpin") != null
		and b.get_node_or_null("Machine/Housing") != null and b.get_node_or_null("Machine/Static") != null, "the builder's nodes")
	var cups := b.get_node_or_null("Machine/Runner/Cups") as MultiMeshInstance3D
	_check(cups != null and cups.multimesh.instance_count == 21, "one cup instance per cup")
	var rot := b.get_node_or_null("Machine/Runner/RotorMesh") as MeshInstance3D
	_check(rot != null and bool(rot.get_meta("skip_prop_collision", false)), "spinning parts never collide")
	var st := b.get_node_or_null("Machine/Static") as MeshInstance3D
	_check(st != null and not st.has_meta("skip_prop_collision") and st.mesh.get_surface_count() > 4, "the static machine collides")
	runner.transform = Transform3D(Basis(Vector3.RIGHT, 0.5), Vector3.ZERO)
	b._process(0.0)
	var gs := b.get_node("Machine/GenSpin") as Node3D
	var v := gs.transform.basis * Vector3.UP
	_check(_near(atan2(v.z, v.y), wrapf(0.5 * 1.6, -PI, PI), 1e-4), "the generator follows the wheel at the ratio")
	_check(not PeltonLabBuilder.pick(b, Vector3(0, 0.4, -2.0), Vector3(0, 0, 1)).is_empty(), "a ray at the machine picks a part")
	var picks: Array = b.get_meta("pelton_picks")
	var labels := picks.map(func(p): return str(p["label"]))
	_check(labels.has("Cups") and labels.has("Housing"), "picks name the cups and the housing")
	b.free()
	var bv := PeltonLabBuilder.build_node(PeltonLabPresets.vertical_spec()) as PeltonLabBuilder
	_check(((bv.get_node("Machine") as Node3D).transform.basis * Vector3.RIGHT).is_equal_approx(Vector3.UP), "the vertical machine stands its shaft up")
	bv.free()


func _test_ports_cam_pack() -> void:
	var d := PeltonLabDesign.solve(PeltonLabPresets.classic_spec())
	var ports := PeltonLabDesign.ports(d)
	var handles := ports.map(func(p): return str(p["handle"]))
	_check(handles == ["res_in_0", "res_out_0", "res_out_1_pos", "res_out_1_neg"], "the four ports")
	var cp := ConnectionPortDefs.default_ports_for_model(PeltonLabBuilder.MODEL_ID, {"pelton_spec": d["spec"]})
	_check(cp.size() == 4, "ConnectionPortDefs builds them for the model")
	var inlet: Vector3 = ports[0]["pos"]
	var a: AABB = d["aabb"]
	_check(a.grow(0.01).has_point(inlet), "the inlet port is on the machine")
	var disc := PeltonLabCam.plate_content(d, true)
	_check((disc["inside"] as Array).size() == 1 + 6 + 21 * 2, "the disc's holes: bore + hub pattern + every cup bolt")
	var spacer := PeltonLabCam.plate_content(d, false)
	_check((spacer["inside"] as Array).size() == 1 + 6, "the spacer's holes: bore + hub pattern")
	_check(DomeLabCam.dxf_document(disc).contains("POLYLINE"), "the disc DXF draws polylines")
	var dir := OS.get_user_data_dir().path_join("peltonlab_selftest_tmp")
	var r := PeltonLabCam.write_all(d, dir)
	_check(bool(r["ok"]) and (r["files"] as Array).size() == 7, "seven files written")
	for f in r["files"]:
		DirAccess.remove_absolute(str(f))
	DirAccess.remove_absolute(dir)
	var pk := PeltonLabDesign.packed_spec(d)
	_check(float(pk["w_m"]) > 0.3 and float(pk["mass_kg"]) > float(d["mass"]["total"]), "the packed crate holds the machine")
	_check(PackedSpec.DYNAMIC_MODELS.has(PeltonLabBuilder.MODEL_ID), "the model has a packing decision")
	var csv := PeltonLabDesign.bom_csv(d)
	_check(csv.contains("Pelton cup") and csv.contains("Generator"), "the BOM lists cups and the generator")


func _test_spec() -> void:
	var s := PeltonLabSpec.resolve({"runner": {"cups": 999, "cup_material": "nope"}, "jets": {"count": 9}})
	_check(int(s["runner"]["cups"]) == PeltonLabSpec.MAX_CUPS, "cups clamp")
	_check(str(s["runner"]["cup_material"]) == "nylon", "an unknown material falls back")
	_check(int(s["jets"]["count"]) == 2, "a horizontal shaft takes at most two jets")
	var j := PeltonLabSpec.to_json_safe(PeltonLabPresets.big_spec())
	var back := PeltonLabSpec.resolve(JSON.parse_string(JSON.stringify(j)))
	_check(PeltonLabSpec.key_of(back) == PeltonLabSpec.key_of(j), "the spec survives JSON")
	_check(PeltonLabSpec.geometry_key(PeltonLabSpec.resolve({"site": {"gross_head_m": 50.0}}))
		== PeltonLabSpec.geometry_key(PeltonLabSpec.default_spec()), "the site is not geometry")
