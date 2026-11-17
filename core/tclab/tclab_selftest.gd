extends SceneTree

## TC designer self-test (offline). Run --import first:
##   Godot --headless --path . --script core/tclab/tclab_selftest.gd
## Standards rows against the sourced tables and the reference GLB, every
## part × size built with every triangle on Godot's front face and every
## clamp face drawn where its port is, the published centre-to-face lengths,
## mates (gap, opposed axes, symmetric, roll), clamp-class matching, a loop
## that closes only once its Fit-length spool solves itself, clashes,
## detach / attach / remove keeping one root per group, the BOM (one gasket
## and one clamp per joint), the spec key round trip, picking, the builder's
## nodes, and the files (GLB re-imported, STL size).

const EXPECTED_CHECKS := 779

var _pass := 0
var _fail := 0


func _ok(cond: bool, what: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		print("FAIL: ", what)


func _near(a: float, b: float, tol: float, what: String) -> void:
	_ok(absf(a - b) <= tol, "%s (%.4f vs %.4f)" % [what, a, b])


func _initialize() -> void:
	TcDesign.clear_cache()
	TcParts.clear_cache()
	_test_standards()
	_test_parts()
	_test_mates()
	_test_loop_fit()
	_test_edits()
	_test_clash_pick()
	_test_bom_key()
	_test_builder_export()
	_test_specialty()
	_test_vessel()
	_test_presets()
	_test_photo_presets()
	_test_world()
	var total := _pass + _fail
	print("tclab selftest: %d passed, %d failed (%d checks)" % [_pass, _fail, total])
	if EXPECTED_CHECKS > 0 and total != EXPECTED_CHECKS:
		print("FAIL: ran %d checks, expected %d (a test function aborted?)" % [total, EXPECTED_CHECKS])
		_fail += 1
	print("tclab selftest: ", "PASS" if _fail == 0 else "FAILED")
	quit(0 if _fail == 0 else 1)


func _test_standards() -> void:
	var prev := 0.0
	for s in TcStandards.SIZES:
		var t := TcStandards.tube(s)
		_ok(float(t["od"]) > prev, "tube OD rises with size %s" % s)
		prev = float(t["od"])
		_ok(float(t["flange"]) > float(t["od"]), "flange wider than the tube at %s" % s)
		_ok(float(t["wall"]) > 1.0 and float(t["wall"]) < 3.0, "wall of %s is a BPE wall" % s)
	# The reference GLB (tri clamp examples.glb) measures 50.5 / 64 mm.
	_near(float(TcStandards.tube("1.5")["flange"]), 50.5, 0.3, "1½\" flange OD matches the reference model")
	_near(float(TcStandards.tube("2")["flange"]), 64.0, 0.3, "2\" flange OD matches the reference model")
	_near(float(TcStandards.tube("1.5")["wall"]), 1.651, 0.01, "1½\" wall 0.065\"")
	_near(float(TcStandards.tube("4")["wall"]), 2.108, 0.01, "4\" wall 0.083\"")
	_ok(TcStandards.clamps_match("1", "1.5"), "1\" and 1½\" share a clamp")
	_ok(TcStandards.clamps_match("0.5", "0.75"), "½\" and ¾\" share the mini clamp")
	_ok(not TcStandards.clamps_match("1.5", "2"), "1½\" and 2\" do not")
	_near(TcStandards.elbow90_ctf("1.5"), 69.85, 0.01, "2CMP 1½\" centre-to-face 2.750\"")
	_near(TcStandards.tee_ctf("2"), 85.725, 0.01, "7MP 2\" centre-to-face 3.375\"")
	_ok(TcStandards.estimates().size() >= 5, "the estimate list is reported")
	print("tclab: estimates still to verify — ", ", ".join(PackedStringArray(TcStandards.estimates())))


func _test_parts() -> void:
	var bad_tris := 0
	var built := 0
	var face_ok := true
	for type in TcParts.TYPE_ORDER:
		for s in TcStandards.SIZES:
			var b := TcParts.build(type, s, {})
			built += 1
			var g: TcGeom = b["geo"]
			if g.vertex_count() == 0:
				_ok(false, "%s %s drew nothing" % [type, s])
				continue
			bad_tris += _bad_windings(g)
			for p in b["ports"]:
				if str(p["kind"]) != "tc":
					continue
				if not _face_at(g, p):
					face_ok = false
					print("tclab: no clamp face at %s %s port %s" % [type, s, p["id"]])
			_ok(float(b["mass_kg"]) > 0.0, "%s %s has a mass" % [type, s])
	_ok(built == TcParts.TYPE_ORDER.size() * TcStandards.SIZES.size(), "every type × size built (%d)" % built)
	_ok(bad_tris == 0, "every triangle is on Godot's front face (%d wrong)" % bad_tris)
	_ok(face_ok, "every clamp port has its flange drawn on its face")
	var e := TcParts.build("elbow90", "1.5", {})
	var pa: Dictionary = e["ports"][0]
	var pb: Dictionary = e["ports"][1]
	_near((pa["pos"] as Vector3).length(), 69.85, 0.01, "elbow port a at the 2CMP centre-to-face")
	_near((pb["pos"] as Vector3).length(), 69.85, 0.01, "elbow port b at the 2CMP centre-to-face")
	_near(rad_to_deg((pa["z"] as Vector3).angle_to(pb["z"])), 90.0, 0.01, "the elbow turns 90°")
	var t := TcParts.build("tee", "2", {})
	_ok((t["ports"] as Array).size() == 3, "a tee has three ports")
	_near(((t["ports"][2] as Dictionary)["pos"] as Vector3).length(), 85.725, 0.01, "tee branch at the 7MP centre-to-face")
	var rt := TcParts.build("reducing_tee", "2", {"branch": "1"})
	_ok(str(rt["ports"][2]["size"]) == "1", "a reducing tee's branch is its own size")
	var sp := TcParts.build("spool", "1.5", {"length_mm": 300.0})
	_near((sp["ports"][1]["pos"] as Vector3).z, 300.0, 0.001, "a spool is its length face to face")
	_near(float(sp["volume_l"]), PI * pow(34.798 * 0.5, 2.0) * 300.0 * 1e-6, 0.002, "spool bore volume")
	var r := TcParts.build("reducer", "2", {"small": "1.5"})
	_ok(str(r["ports"][1]["size"]) == "1.5", "a reducer's small end")
	var rc := TcParts.build("reducing_cap", "1.5", {"small": "0.5"})
	_ok(str(rc["ports"][1]["size"]) == "0.5" and TcStandards.clamp_class(str(rc["ports"][1]["size"])) == "mini",
		"the reducing cap carries a mini clamp end (the reference ½\" on 1½\")")
	var n := TcParts.build("tc_npt_m", "1.5", {"npt": "0.5"})
	_ok(str(n["ports"][1]["kind"]) == "npt_m", "TC × MNPT ends in a male thread")
	var c := TcParts.build("cap_npt", "1.5", {"npt": "0.5"})
	_ok(TcParts.can_mate(n["ports"][1], c["ports"][1])["ok"], "a male ½\" NPT mates a female ½\"")
	_ok(not TcParts.can_mate(n["ports"][1], n["ports"][1])["ok"], "male does not mate male")
	_ok(TcParts.build("elbow90", "1.5", {}) == e, "built parts are cached")


## Triangles whose winding disagrees with their normals (Godot's front face:
## cross(b − a, c − a) · n < 0).
func _bad_windings(g: TcGeom) -> int:
	var bad := 0
	var mats := g.get_mats()
	for k in mats:
		var v: PackedVector3Array = mats[k]["v"]
		var nn: PackedVector3Array = mats[k]["n"]
		var i := 0
		while i + 2 < v.size():
			var f := (v[i + 1] - v[i]).cross(v[i + 2] - v[i])
			if f.length() > 1e-9 and f.dot(nn[i] + nn[i + 1] + nn[i + 2]) > 0.0:
				bad += 1
			i += 3
	return bad


func _face_at(g: TcGeom, p: Dictionary) -> bool:
	var pos: Vector3 = p["pos"]
	var z: Vector3 = p["z"]
	var rf := float(TcStandards.tube(str(p["size"]))["r_flange"])
	var mats := g.get_mats()
	for k in mats:
		for v in (mats[k]["v"] as PackedVector3Array):
			var d := v - pos
			if absf(d.dot(z)) < 0.05 and absf((d - z * d.dot(z)).length() - rf) < 0.05:
				return true
	return false


func _test_mates() -> void:
	var r := TcAssembly.add_part(TcSpec.empty(), "spool", "1.5", {"length_mm": 200.0}, Transform3D.IDENTITY)
	var s: Dictionary = r[0]
	var p1: String = r[1]
	r = TcAssembly.add_part(s, "elbow90", "1.5", {}, Transform3D.IDENTITY, {"target": p1 + ":b", "own": "a"})
	s = r[0]
	var p2: String = r[1]
	var d := TcDesign.solve(s)
	var res: Dictionary = d["res"]
	var fa: Transform3D = res["parts"][p1]["xf"] * TcParts.port_xform(res["parts"][p1]["built"]["ports"][1])
	var fb: Transform3D = res["parts"][p2]["xf"] * TcParts.port_xform(res["parts"][p2]["built"]["ports"][0])
	_near(fa.origin.distance_to(fb.origin), TcStandards.GASKET_GAP_MM, 0.001, "mated faces a gasket apart")
	_near(fa.basis.z.dot(fb.basis.z), -1.0, 1e-5, "mated port axes opposed")
	_near((fb.origin - fa.origin).dot(fa.basis.z), TcStandards.GASKET_GAP_MM, 0.001, "the gap lies along the axis")
	# The same joint written the other way round places the elbow the same.
	var s2: Dictionary = s.duplicate(true)
	var j: Dictionary = s2["joints"][0]
	var tmp: String = j["a"]
	j["a"] = j["b"]
	j["b"] = tmp
	var res2: Dictionary = TcDesign.solve(s2)["res"]
	_near((res2["parts"][p2]["xf"] as Transform3D).origin.distance_to((res["parts"][p2]["xf"] as Transform3D).origin), 0.0, 1e-3,
		"a joint is symmetric")
	# Roll 90 swings the elbow's far end about the spool axis.
	var s3 := TcAssembly.set_joint(s, p1 + ":b", p2 + ":a", {"roll_deg": 90.0})
	var res3: Dictionary = TcDesign.solve(s3)["res"]
	var tip0: Vector3 = res["parts"][p2]["xf"] * (res["parts"][p2]["built"]["ports"][1]["pos"] as Vector3)
	var tip1: Vector3 = res3["parts"][p2]["xf"] * (res3["parts"][p2]["built"]["ports"][1]["pos"] as Vector3)
	var axis := fa.origin
	_near(Vector2(tip0.x, tip0.y).length(), Vector2(tip1.x, tip1.y).length(), 0.01, "roll keeps the distance from the spool axis")
	_near(tip0.z, tip1.z, 0.01, "roll keeps the height along the spool axis")
	_ok(tip0.distance_to(tip1) > 50.0, "roll 90 swings the elbow's end round")
	var _a := axis
	# A 2" spool on a 1½" elbow is refused by the checks.
	var bad := TcAssembly.add_part(s, "spool", "2", {}, Transform3D.IDENTITY, {"target": p2 + ":b", "own": "a"})
	var dbad := TcDesign.solve(bad[0])
	var errs := (dbad["checks"] as Array).filter(func(c): return str(c["level"]) == "error")
	_ok(errs.size() == 1, "a 2\" end on a 1½\" face is an error")
	var ok1 := TcAssembly.add_part(s, "spool", "1", {}, Transform3D.IDENTITY, {"target": p2 + ":b", "own": "a"})
	_ok((TcDesign.solve(ok1[0])["checks"] as Array).filter(func(c): return str(c["level"]) == "error").is_empty(),
		"a 1\" end mates a 1½\" face (one clamp size)")


func _test_loop_fit() -> void:
	var s := TcPresets.square_loop()
	var d := TcDesign.solve(s)
	var res: Dictionary = d["res"]
	_ok((res["closing"] as Array).size() == 1, "the square loop has one closing joint")
	var cj: Dictionary = res["joints"][int(res["closing"][0])]
	_ok(float(cj["err_mm"]) < 0.05, "the fit spool closes the loop (%.3f mm)" % float(cj["err_mm"]))
	var fit_id := ""
	for p in s["parts"]:
		if bool((p["params"] as Dictionary).get("fit", false)):
			fit_id = str(p["id"])
	_near(float((res["fit"] as Dictionary).get(fit_id, 0.0)), 200.0, 0.05, "the fit spool solved to its opposite side")
	_ok((d["checks"] as Array).filter(func(c): return str(c["level"]) == "warn" and str(c["text"]).begins_with("A loop")).is_empty(),
		"no loop warning once it closes")
	# Without Fit length the same loop misses by the 80 mm the spool is short.
	var s2: Dictionary = s.duplicate(true)
	for p in s2["parts"]:
		if str(p["id"]) == fit_id:
			p["params"]["fit"] = false
	var d2 := TcDesign.solve(s2)
	var cj2: Dictionary = d2["res"]["joints"][int(d2["res"]["closing"][0])]
	_near(float(cj2["err_mm"]), 80.0, 0.5, "without Fit length the loop misses by 80 mm")
	_ok((d2["checks"] as Array).filter(func(c): return str(c["text"]).begins_with("A loop")).size() == 1,
		"and the checks say so")
	var cut_l := 0.0
	for c in d["bom"]["cuts"]:
		if str(c["id"]) == fit_id:
			cut_l = float(c["length_mm"])
	_near(cut_l, 200.0, 0.05, "the cut list carries the fitted length")


func _test_edits() -> void:
	var s := TcPresets.elbow_run()
	var d := TcDesign.solve(s)
	var res: Dictionary = d["res"]
	var ids: Array = res["order"]
	_ok((res["comps"] as Array).size() == 1, "the elbow run is one group")
	var mid: String = ids[2]
	var cap: String = ids[ids.size() - 1]
	var cap_before: Vector3 = (res["parts"][cap]["xf"] as Transform3D).origin
	var s2 := TcAssembly.remove_part(s, res, mid)
	var res2: Dictionary = TcDesign.solve(s2)["res"]
	_ok((res2["comps"] as Array).size() == 2, "removing a middle part leaves two groups")
	var roots := 0
	for p in s2["parts"]:
		if p.has("xf"):
			roots += 1
	_ok(roots == 2, "each group keeps one root (%d)" % roots)
	_near((res2["parts"][cap]["xf"] as Transform3D).origin.distance_to(cap_before), 0.0, 0.01, "the far group stays where it was")
	# Detach the elbow: it and what hangs off it become their own group.
	var elbow: String = ids[1]
	var s3 := TcAssembly.detach(s, res, elbow)
	var res3: Dictionary = TcDesign.solve(s3)["res"]
	_ok((res3["comps"] as Array).size() == 2, "detaching makes two groups")
	_ok(TcAssembly.group_of(res3, elbow).size() == ids.size() - 1, "the detached group carries everything past it")
	_near((res3["parts"][cap]["xf"] as Transform3D).origin.distance_to(cap_before), 0.0, 0.01, "detaching moves nothing")
	# Move that group and attach it back where it was: same pose.
	var moved := TcAssembly.set_root_xf(s3, elbow, Transform3D(Basis.IDENTITY, Vector3(500, 0, 0)))
	var res4: Dictionary = TcDesign.solve(moved)["res"]
	_ok((res4["parts"][cap]["xf"] as Transform3D).origin.distance_to(cap_before) > 100.0, "moving a root carries its group")
	var back := TcAssembly.attach(moved, res4, elbow, "a", ids[0] + ":b", 0.0)
	var res5: Dictionary = TcDesign.solve(back)["res"]
	_ok((res5["comps"] as Array).size() == 1, "attaching joins the groups")
	_near((res5["parts"][cap]["xf"] as Transform3D).origin.distance_to(cap_before), 0.0, 0.01, "and puts it back exactly")
	_near((res5["parts"][ids[0]]["xf"] as Transform3D).origin.distance_to((res["parts"][ids[0]]["xf"] as Transform3D).origin), 0.0, 0.01,
		"the target group did not move")


func _test_clash_pick() -> void:
	var s := TcSpec.empty()
	var r := TcAssembly.add_part(s, "spool", "2", {"length_mm": 300.0}, Transform3D.IDENTITY)
	s = r[0]
	r = TcAssembly.add_part(s, "spool", "2", {"length_mm": 300.0}, Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(-150, 0, 150)))
	s = r[0]
	var d := TcDesign.solve(s)
	_ok((d["clashes"] as Array).size() == 1, "two crossed spools clash")
	_ok((TcDesign.solve(TcPresets.elbow_run())["clashes"] as Array).is_empty(), "the elbow run has no clash")
	_ok((TcDesign.solve(TcPresets.manifold())["clashes"] as Array).is_empty(), "the manifold has no clash")
	var res: Dictionary = TcDesign.solve(TcPresets.elbow_run())["res"]
	var first: String = res["order"][0]
	var mid: Vector3 = (res["parts"][first]["xf"] as Transform3D) * Vector3(0, 0, 76)
	var hit := TcAssembly.pick(res, mid + Vector3(0, 0, 0) + Vector3(600, 0, 0), Vector3(-1, 0, 0))
	_ok(str(hit.get("kind", "")) == "part" and str(hit.get("id", "")) == first, "a ray across a spool picks it (%s)" % str(hit))
	var op: Dictionary = res["open"][0]
	var pp: Vector3 = (op["xf"] as Transform3D).origin
	var oz: Vector3 = (op["xf"] as Transform3D).basis.z
	var hit2 := TcAssembly.pick(res, pp + oz * 400.0, -oz)
	_ok(str(hit2.get("kind", "")) == "port" and str(hit2.get("id", "")) == str(op["ref"]), "a ray onto an open face picks the port")
	var jf: Transform3D = res["joints"][0]["frame"]
	var hit3 := TcAssembly.pick(res, jf.origin + jf.basis.x * 400.0, -jf.basis.x)
	_ok(str(hit3.get("kind", "")) == "joint", "a ray onto a clamp picks the joint")


func _test_bom_key() -> void:
	var d := TcDesign.solve(TcPresets.elbow_run())
	var bom: Dictionary = d["bom"]
	var njo := (d["res"]["joints"] as Array).size()
	_ok(int(bom["gaskets"]) == njo and int(bom["clamps"]) == njo, "one gasket and one clamp per joint (%d)" % njo)
	_ok(float(bom["mass_kg"]) > 0.3 and float(bom["mass_kg"]) < 5.0, "the elbow run weighs %.2f kg" % float(bom["mass_kg"]))
	var csv := TcBom.to_csv(bom)
	_ok(csv.contains("90° elbow") and csv.contains("gasket"), "the CSV lists the parts and gaskets")
	var spec: Dictionary = d["spec"]
	var round_trip: Variant = JSON.parse_string(JSON.stringify(spec))
	_ok(TcSpec.key_of(round_trip) == TcSpec.key_of(spec), "a spec saved as JSON keeps its key")
	var before := TcDesign.misses
	TcDesign.solve(round_trip)
	_ok(TcDesign.misses == before, "and hits the cache")
	var m := TcDesign.solve(TcPresets.manifold())
	_ok(int(m["stats"]["open_ports"]) == 4, "the manifold leaves four open ends (two threads, a barb, a mini clamp)")


func _size_of(type: String, size: String, params: Dictionary = {}) -> Vector3:
	return (TcParts.build(type, size, params)["bounds"] as AABB).size


func _test_specialty() -> void:
	# Against the reference GLB (tri clamp examples / Biochar Reactor).
	var sg := _size_of("sight_glass", "1.5", {"length_mm": 153.0})
	_near(maxf(sg.x, sg.y), 74.0, 3.0, "1½\" sight glass collars ≈ the model's 74 mm")
	_near(sg.z, 153.0, 9.0, "1½\" sight glass length ≈ the model's 153 mm")
	var bf := TcParts.build("butterfly", "2", {"manual": false})
	var bfl := ((bf["ports"][1] as Dictionary)["pos"] as Vector3).z
	_near(bfl, 48.0, 4.0, "2\" butterfly face to face ≈ the model's 48 mm")
	_near((bf["bounds"] as AABB).size.x, 91.0, 3.0, "2\" butterfly body ≈ the model's 91 mm")
	var with_h := TcParts.build("butterfly", "2", {"manual": true})
	_ok((with_h["geo"] as TcGeom).vertex_count() > (bf["geo"] as TcGeom).vertex_count(), "a manual valve draws its handle")
	var dep := TcParts.build("dephlegmator", "2", {"length_mm": 457.2, "shell": "2.5"})
	var wports := (dep["ports"] as Array).filter(func(q): return str(q["kind"]) == "npt_f")
	_ok(wports.size() == 2, "a dephlegmator has two water bosses")
	_near((dep["bounds"] as AABB).size.y, 64.0, 2.0, "its jacket ≈ the model's 65 mm shell")
	var el := TcParts.build("heating_element", "2", {"length_mm": 300.0})
	_near(-(el["bounds"] as AABB).position.z, 300.0, 6.0, "the element's loops reach ~300 mm through the port")
	_ok(float((el["capsules"][0][1] as Vector3).z) > 0.0, "and only its head (outside) is a body")
	# Stems: an actuator mates a valve's stem.
	var r := TcAssembly.add_part(TcSpec.empty(), "ball_valve", "1.5", {"manual": false}, Transform3D.IDENTITY)
	var s: Dictionary = r[0]
	r = TcAssembly.add_part(s, "actuator_pneumatic", "1.5", {}, Transform3D.IDENTITY, {"target": str(r[1]) + ":stem", "own": "stem"})
	var d := TcDesign.solve(r[0])
	_ok((d["checks"] as Array).filter(func(c): return str(c["level"]) == "error").is_empty() and (d["res"]["comps"] as Array).size() == 1,
		"an actuator mounts on a valve stem")
	var act: Dictionary = d["res"]["parts"][str(r[1])]
	_ok(((act["xf"] as Transform3D).basis.z).dot(Vector3.UP) > 0.99, "and stands up off it")
	_ok((d["clashes"] as Array).is_empty(), "with no clash")
	var th := TcParts.build("thermometer", "1.5", {"mount": "npt", "npt": "0.5"})
	var cn := TcParts.build("cap_npt", "1.5", {"npt": "0.5"})
	_ok(TcParts.can_mate(th["ports"][0], cn["ports"][1])["ok"], "a threaded thermometer goes in a ½\" FNPT cap")
	_ok(TcStandards.short_ctf("2") < TcStandards.elbow90_ctf("2"), "a short elbow is shorter than a 2CMP")
	var se := TcParts.build("elbow90", "2", {"short": true})
	_near(((se["ports"][0] as Dictionary)["pos"] as Vector3).length(), TcStandards.short_ctf("2"), 0.01, "the short elbow's face at its CTF")


func _test_vessel() -> void:
	var p := TcVessel.resolve({"od_mm": 340.0, "height_mm": 650.0, "jacket": "full", "jacket_gap_mm": 26.0,
		"ports": [{"id": "s", "kind": "tc", "size": "2", "face": "shell", "angle_deg": 90.0, "h_mm": 190.0, "stub_mm": 20.0},
			{"id": "t", "kind": "tc", "size": "2", "face": "lid", "angle_deg": 0.0, "r_mm": 0.0, "stub_mm": 30.0},
			{"id": "b", "kind": "npt", "size": "0.5", "face": "bottom", "angle_deg": 0.0, "r_mm": 50.0, "stub_mm": 12.0}]})
	_near(TcVessel.jacket_r(p), 198.0, 0.01, "the jacket's outside radius (340 + 2 × 26 + walls = 396)")
	var b := TcParts.build("vessel", "2", p)
	var ports := {}
	for q in b["ports"]:
		ports[str(q["id"])] = q
	var s: Dictionary = ports["s"]
	_near((s["pos"] as Vector3).x, 218.0, 0.01, "a shell nozzle stands its stub past the jacket")
	_near((s["pos"] as Vector3).y, 190.0, 0.01, "at its height")
	_ok((s["z"] as Vector3).dot(Vector3.RIGHT) > 0.999, "facing out at 90°")
	var t: Dictionary = ports["t"]
	_near((t["pos"] as Vector3).y, 650.0 + 2.0 + TcVessel.lid_depth(p) + 30.0, 0.5, "the lid nozzle stands on the dome's crown")
	_ok(str(ports["b"]["kind"]) == "npt_f" and (ports["b"]["z"] as Vector3).dot(Vector3.DOWN) > 0.999, "a bottom bung faces down")
	_near(float(b["volume_l"]), PI * 168.0 * 168.0 * 650.0 * 1e-6, 0.01, "a flat-bottomed shell holds π r² h")
	var b2 := TcParts.build("vessel", "2", TcVessel.resolve(p.merged({"bottom": "ellipsoidal"}, true)))
	_ok(float(b2["volume_l"]) > float(b["volume_l"]), "a 2:1 head adds volume")
	var cut := TcParts.build("vessel", "2", p.merged({"cutaway": true}, true))
	_ok((cut["geo"] as TcGeom).vertex_count() != (b["geo"] as TcGeom).vertex_count(), "the cutaway draws the vessel cut open")
	# Dragging: a ray onto the shell moves the nozzle there.
	var a := deg_to_rad(75.0)
	var target := Vector3(sin(a) * 300.0, 300.0, cos(a) * 300.0)
	var o := target + Vector3(sin(a), 0.0, cos(a)) * 800.0
	var moved := TcVessel.surface_hit(p, p["ports"][0], o, (target - o).normalized())
	_near(float(moved["angle_deg"]), 75.0, 1.0, "a drag onto the shell sets the angle")
	_near(float(moved["h_mm"]), 300.0, 1.0, "and the height")
	var lid_hit := TcVessel.surface_hit(p, p["ports"][1], Vector3(80, 2000, 0), Vector3.DOWN)
	_near(float(lid_hit["r_mm"]), 80.0, 1.0, "a drag on the lid sets the nozzle's radius")
	# In an assembly: a part on a nozzle; removing the nozzle drops the joint.
	var r := TcAssembly.add_part(TcSpec.empty(), "vessel", "2", p, Transform3D.IDENTITY)
	var sp: Dictionary = r[0]
	var vid: String = r[1]
	r = TcAssembly.add_part(sp, "ball_valve", "2", {}, Transform3D.IDENTITY, {"target": vid + ":s", "own": "a"})
	sp = r[0]
	var d := TcDesign.solve(sp)
	_ok((d["res"]["joints"] as Array).size() == 1 and (d["clashes"] as Array).is_empty(), "a valve on a shell nozzle, no clash")
	var pp: Dictionary = TcSpec.part_of(sp, vid)["params"].duplicate(true)
	pp["ports"] = (pp["ports"] as Array).filter(func(q): return str(q["id"]) != "s")
	var sp2 := TcAssembly.set_part(sp, vid, {"params": {"ports": pp["ports"]}})
	_ok((TcSpec.resolve(sp2)["joints"] as Array).is_empty(), "removing the nozzle drops its joint")
	# A spool pushed through the shell is a clash.
	var r2 := TcAssembly.add_part(TcSpec.empty(), "vessel", "2", p, Transform3D.IDENTITY)
	r2 = TcAssembly.add_part(r2[0], "spool", "2", {"length_mm": 600.0}, Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(-300, 300, 0)))
	_ok((TcDesign.solve(r2[0])["clashes"] as Array).size() == 1, "a spool through the vessel is a clash")


## 2026-11-08: the reactor's lid as the model has it, what a vessel can
## stand on, the handle ring, the bowl reducer and the designs made from
## the user's photos.
func _test_photo_presets() -> void:
	var rv := TcVessel.resolve(TcPresets.reactor_vessel())
	_near(TcVessel.lid_od(rv), 380.0, 0.01, "the reactor's lid flange is Ø380 (the model's ring is r 182–192)")
	_near(TcVessel.lid_dome_od(rv), 342.0, 0.01, "its dome Ø342")
	_near(TcVessel.lid_depth(rv), 59.0, 0.01, "59 mm high")
	_ok(TcVessel.lid_od(rv) < TcVessel.jacket_r(rv) * 2.0, "the lid sits inside the jacket's rim (it was Ø516, wider than the vessel)")
	_near(TcVessel.lid_flange_t(rv), TcVessel.LID_FLANGE_MM, 0.01, "the dome stands on a flange ring")
	_near(TcVessel.face_y(rv, "lid", 0.0), 650.0 + TcVessel.LID_FLANGE_MM + 59.0 + 2.0, 0.01, "the crown is flange + dome above the rim")
	_near(TcVessel.face_y(rv, "lid", 185.0), 650.0 + TcVessel.LID_FLANGE_MM, 0.01, "past the dome the lid is the flat flange")
	var plain := TcVessel.resolve({"od_mm": 300.0, "height_mm": 300.0})
	_near(TcVessel.lid_flange_t(plain), 0.0, 0.01, "a lid with no dome diameter is all dome, as before")
	_near(TcVessel.lid_dome_od(plain), TcVessel.lid_od(plain), 0.01, "its dome is the lid")
	for key in ["ring_stand_reactor", "tall_tank", "horizontal_tank", "cylinder", "collection_pot"]:
		_ok(TcVessel.PRESETS.has(key), "vessel preset %s" % key)
		var vp := TcVessel.resolve(TcVessel.PRESETS[key]["params"])
		var g := TcGeom.new()
		var built := TcVessel.build(g, vp)
		_ok(_bad_windings(g) == 0, "%s: every triangle on the front face (%d bad)" % [key, _bad_windings(g)])
		_ok(float(built["volume_l"]) > 5.0, "%s holds %.0f L" % [key, float(built["volume_l"])])
	# A ring stand reaches the floor: its lowest point is the legs' height below the bottom.
	var rs := TcVessel.resolve(TcVessel.PRESETS["ring_stand_reactor"]["params"])
	var g2 := TcGeom.new()
	TcVessel.build(g2, rs)
	var bb := g2.aabb()
	_near(bb.position.y, -TcVessel.head_depth(rs, "bottom") - float(rs["leg_h_mm"]), 1.5, "the ring stand's casters reach the legs' height below the bottom head")
	_ok(bb.size.x > float(rs["od_mm"]) * 1.15, "the floor ring is wider than the vessel (%.0f mm)" % bb.size.x)
	_ok(bb.end.y > float(rs["height_mm"]) + float(rs["handle_ring_h_mm"]), "the handle ring stands over the top")
	var no_ring := TcGeom.new()
	TcVessel.build(no_ring, TcVessel.resolve((rs as Dictionary).merged({"handle_ring": false}, true)))
	_ok(no_ring.aabb().end.y < bb.end.y - 50.0, "and goes with its box unticked")
	# A skid hangs off the shell's −Z side.
	var hz := TcVessel.resolve(TcVessel.PRESETS["horizontal_tank"]["params"])
	var g3 := TcGeom.new()
	TcVessel.build(g3, hz)
	_near(g3.aabb().position.z, -(float(hz["od_mm"]) * 0.5 + float(hz["leg_h_mm"]) + 15.0), 1.5, "the skid's casters are the leg height below the shell, on its −Z side")
	_near(g3.aabb().end.z, float(hz["od_mm"]) * 0.5, 1.0, "nothing on the other side")
	# The bowl reducer.
	var br := TcParts.build("bowl_reducer", "6", {"small": "2"})
	var bp := {}
	for q in br["ports"]:
		bp[str(q["id"])] = q
	_ok(str(bp["a"]["size"]) == "6" and str(bp["b"]["size"]) == "2", "a bowl reducer goes 6\" to 2\"")
	var cone := TcParts.build("reducer", "6", {"small": "2"})
	var cb := {}
	for q2 in cone["ports"]:
		cb[str(q2["id"])] = q2
	_ok((bp["b"]["pos"] as Vector3).z < (cb["b"]["pos"] as Vector3).z * 0.7, "and is much shorter than the cone (%.0f vs %.0f mm)" % [(bp["b"]["pos"] as Vector3).z, (cb["b"]["pos"] as Vector3).z])
	_ok(TcFlowPaths.TYPE_RULES.has("bowl_reducer"), "the process network knows it is a pipe")
	# The barrel gasometers and the small generator (the user's models).
	_near(TcUnits.barrel_capacity_l("barrel_30"), 56.8 * 0.8, 1e-6, "a 30 gal gasometer holds 0.8 of its 15 gal float (%.1f L)" % TcUnits.barrel_capacity_l("barrel_30"))
	_near(TcUnits.barrel_capacity_l("barrel_55"), 113.6 * 0.8, 1e-6, "the 55 gal one 0.8 of a 30 gal float (%.1f L)" % TcUnits.barrel_capacity_l("barrel_55"))
	_ok(absf(TcUnits.holder_stroke_mm("barrel_30", 0.0) - 440.0) < 40.0, "its float rises about as far as the model draws it (%.0f mm, model 440)" % TcUnits.holder_stroke_mm("barrel_30", 0.0))
	_ok(TcUnits.barrel_hold_kpa("barrel_30") > 0.15 and TcUnits.barrel_hold_kpa("barrel_30") < 0.5, "the float's weight holds the gas at a few tenths of a kPa (%.2f)" % TcUnits.barrel_hold_kpa("barrel_30"))
	var gh := TcParts.build("gas_holder", "2", {})
	_ok(str(gh["params"]["style"]) == "barrel_30", "a new gas holder is the 30 gal barrel gasometer")
	var gb: AABB = (gh["geo"] as TcGeom).aabb()
	_near(gb.size.x, 526.0 + 14.0, 3.0, "its base barrel is Ø526 (hoops 14 mm more)")
	_ok(gb.size.y > 866.0 and gb.size.y < 866.0 + 500.0, "drawn with the float part way up (%.0f mm tall)" % gb.size.y)
	var g55 := TcParts.build("gas_holder", "2", {"style": "barrel_55"})
	_near(float(g55["params"]["volume_l"]), TcUnits.barrel_capacity_l("barrel_55"), 1e-6, "the 55 gal style sets its own capacity")
	_ok((g55["geo"] as TcGeom).aabb().size.x > gb.size.x + 40.0, "and is the bigger barrel")
	var old := TcParts.build("gas_holder", "2", {"volume_l": 300.0, "hold_kpa": 0.8})
	_ok(str(old["params"]["style"]) == "bell" and absf(float(old["params"]["volume_l"]) - 300.0) < 1e-9, "a holder saved before the barrels is still the 300 L steel bell")
	for st in ["barrel_30", "barrel_55", "bell"]:
		var gf := TcGeom.new()
		var gbase := TcGeom.new()
		TcUnits.gas_holder(gf, "2", 300.0, 0.5, st, "float", 0.0)
		TcUnits.gas_holder(gbase, "2", 300.0, 0.5, st, "base")
		_ok(_bad_windings(gf) == 0 and _bad_windings(gbase) == 0, "%s: float and base wound to the front" % st)
		_ok(gf.get_mats().has("bell") and not gbase.get_mats().has("bell"), "%s: the float is its own surface, apart from the base" % st)
	var gen := TcParts.build("genset", "2", {})
	_ok(str(gen["params"]["model"]) == "small" and absf(float(gen["params"]["rated_kw"]) - 0.75) < 1e-9 and absf(float(gen["params"]["min_kw"]) - 0.35) < 1e-9,
		"a new generator is the small one, 350–750 W")
	var genb: AABB = (gen["geo"] as TcGeom).aabb()
	_ok(absf(genb.size.x - 560.0) < 30.0 and absf(genb.size.y - 620.0) < 40.0, "drawn to the model's size (%.0f wide, %.0f high; model 560 × 620)" % [genb.size.x, genb.size.y])
	_ok(_bad_windings(gen["geo"]) == 0, "wound to the front")
	_ok(TcParts.part_name("genset", "2", gen["params"]).begins_with("350–750 W"), "named by its range (%s)" % TcParts.part_name("genset", "2", gen["params"]))
	var old_gen := TcParts.build("genset", "2", {"rated_kw": 2.5, "efficiency": 0.22})
	_ok(str(old_gen["params"]["model"]) == "skid" and float(old_gen["params"]["min_kw"]) == 0.0, "a genset saved before it is still the 2.5 kW skid set")
	var chain := TcDesign.solve(TcPresets.builtin("biochar_genset"))
	var kinds := {}
	for cid in chain["res"]["order"]:
		var cb2: Dictionary = chain["res"]["parts"][cid]["built"]
		if str(cb2["type"]) in ["gas_holder", "genset"]:
			kinds[str(cb2["type"])] = cb2["params"]
	_ok(str((kinds.get("gas_holder", {}) as Dictionary).get("style", "")) == "barrel_30" and str((kinds.get("genset", {}) as Dictionary).get("model", "")) == "small",
		"the reactor → genset chain uses the barrel gasometer and the small generator")
	# The designs.
	for id in ["ring_stand_reactor", "tall_tank", "horizontal_receiver", "parts_kit"]:
		var d := TcDesign.solve(TcPresets.builtin(id))
		var errs := (d["checks"] as Array).filter(func(c): return str(c["level"]) == "error")
		_ok(not (d["res"]["order"] as Array).is_empty() and errs.is_empty(), "%s solves with no error (%d parts, %d errors)" % [id, (d["res"]["order"] as Array).size(), errs.size()])
		_ok((d["clashes"] as Array).is_empty(), "%s: nothing clashes (%d)" % [id, (d["clashes"] as Array).size()])
		var b3: AABB = d["stats"]["bounds_mm"]
		_ok(b3.position.y > -8.0, "%s stands on the floor (lowest point %.0f mm)" % [id, b3.position.y])
	var hd := TcDesign.solve(TcPresets.builtin("horizontal_receiver"))
	var hb: AABB = hd["stats"]["bounds_mm"]
	_ok(hb.size.z > hb.size.y and hb.size.z > 1000.0, "the receiver lies on its side (%.0f long, %.0f high)" % [hb.size.z, hb.size.y])


func _test_presets() -> void:
	for bi in TcPresets.builtins():
		var d := TcDesign.solve(bi["spec"])
		var bad := (d["checks"] as Array).filter(func(c): return str(c["level"]) != "info")
		_ok(bad.is_empty(), "%s solves clean (%s)" % [bi["id"], str(bad.map(func(c): return c["text"]))])
		_ok((d["clashes"] as Array).is_empty(), "%s has no clash" % bi["id"])
	var d2 := TcDesign.solve(TcPresets.builtin("biochar_reactor"))
	var res: Dictionary = d2["res"]
	_ok((res["closing"] as Array).size() == 1 and float(res["joints"][int(res["closing"][0])]["err_mm"]) < 0.05,
		"the reactor's condenser loop closes")
	var xs: Array = []
	var types := {}
	for id in res["order"]:
		var bt := str(res["parts"][id]["built"]["type"])
		types[bt] = int(types.get(bt, 0)) + 1
		if bt == "dephlegmator":
			xs.append((res["parts"][id]["xf"] as Transform3D).origin.x)
	xs.sort()
	_ok(xs.size() == 3 and absf(float(xs[0]) + float(xs[2])) < 0.5 and absf(float(xs[1])) < 0.5, "three condenser columns, symmetric (%s)" % str(xs))
	_ok(int(types.get("vessel", 0)) == 1 and int(types.get("heating_element", 0)) == 2 and int(types.get("butterfly", 0)) == 1,
		"the reactor carries its vessel, two bottom elements and butterfly drain")
	var labels: Dictionary = d2["spec"]["labels"]
	var gas := false
	for k in labels:
		if str(labels[k]["kind"]) == "woodgas":
			gas = true
	_ok(gas, "the woodgas outlet is labelled")
	var bb: AABB = d2["stats"]["bounds_mm"]
	# A flat double bottom (no legs): the jacket's own bottom is the floor,
	# the two elements' heads sit between it and the inner bottom:
	# the feet are the lowest thing.
	_ok(bb.position.y > -170.0 and bb.position.y < -150.0, "the reactor stands on its jacket's flat bottom (lowest %.1f mm)" % bb.position.y)


## Phase 7–8: the placed assembly (catalog, world build, LOD + collision,
## crew pieces, connection ports, the graph binding, packing).
func _test_world() -> void:
	_ok(TcBuilder.handles("tclab_assembly") and TcBuilder.handles("tclab_biochar_reactor"), "the catalog ids are the builder's")
	_ok(not TcBuilder.handles("tclab_nothing") and not TcBuilder.handles("dome"), "and nothing else")
	var spec := TcBuilder.spec_for_model("tclab_biochar_reactor")
	_ok(not spec.is_empty() and str(spec["binds"]) == "Biochar Reactor", "a catalog id with no record builds its built-in, bound to the Biochar Reactor")
	var d := TcDesign.solve(spec)
	var off := TcDesign.world_offset(d)
	var bb: AABB = d["stats"]["bounds_mm"]
	_near(bb.position.y + off.y, 0.0, 0.01, "the placed assembly stands on y = 0")
	_near(bb.position.x + bb.size.x * 0.5 + off.x, 0.0, 0.01, "centred in x")
	_near(bb.position.z + bb.size.z * 0.5 + off.z, 0.0, 0.01, "and in z")
	TcBuilder._world_cache.clear()
	TcBuilder._world_order.clear()
	var n0 := TcBuilder.world_builds
	var node := TcBuilder.build_node(spec)
	var near := node.get_node_or_null("Mesh") as MeshInstance3D
	var far := node.get_node_or_null("MeshFar") as MeshInstance3D
	_ok(near != null and far != null, "a placed assembly draws a near and a far mesh")
	if near != null and far != null:
		_ok(bool(near.get_meta("skip_prop_collision", false)) and not far.has_meta("skip_prop_collision"), "the far mesh is the collision")
		_ok(near.visibility_range_end > 0.0 and is_equal_approx(far.visibility_range_begin, near.visibility_range_end), "they hand over at one distance")
		var tn := near.mesh.get_faces().size()
		var tf := far.mesh.get_faces().size()
		_ok(tf > 0 and tf < tn * 0.4, "the far mesh has under 40 %% of the triangles (%d vs %d)" % [tf / 3, tn / 3])
		var ab := near.mesh.get_aabb()
		_near(ab.position.y, 0.0, 0.002, "its mesh stands on the ground")
		_near(ab.size.y, bb.size.y * 0.001, 0.002, "at the design's height")
		_ok(near.mesh.get_surface_count() <= 16, "one surface per material (%d)" % near.mesh.get_surface_count())
	_ok(is_equal_approx(TcGeom.seg_scale, 1.0), "the far build puts the segment scale back")
	var node2 := TcBuilder.build_node(spec)
	_ok(TcBuilder.world_builds == n0 + 1 and (node2.get_node("Mesh") as MeshInstance3D).mesh == near.mesh, "a second copy shares the cached meshes")
	node.free()
	node2.free()
	# Crew pieces.
	var pn := TcBuilder.build_node(spec, "P", {"pieces": true})
	var pieces := 0
	var vessel_first := false
	var deeper := true
	for c in pn.get_children():
		if not bool(c.get_meta("structure_piece", false)):
			continue
		pieces += 1
		if str(c.get_meta("piece_kind", "")) == "frames":
			vessel_first = int(c.get_meta("piece_order", -1)) == 0
		elif str(c.name).begins_with("P_") and int(c.get_meta("piece_order", 0)) < 1:
			deeper = false
	_ok(pieces == (d["res"]["order"] as Array).size() + int(d["bom"]["clamps"]), "every part and clamp is a crew piece (%d)" % pieces)
	_ok(vessel_first and deeper, "the vessel goes up first, the fittings after it")
	pn.free()
	# Connection ports + the graph binding.
	var ports := TcDesign.connection_ports(d)
	_ok(ports.size() == (d["spec"]["labels"] as Dictionary).size(), "every labelled end is a port (%d)" % ports.size())
	var handles := {}
	var inside := true
	for q in ports:
		var h := str(q["handle_id"])
		if not h.is_empty():
			handles[h] = str(q["resource_kind"])
		var pos := Vector3(float(q["x"]), float(q["y"]), float(q["z"]))
		var nb := AABB(Vector3(-bb.size.x * 0.0005, 0.0, -bb.size.z * 0.0005), bb.size * 0.001).grow(0.01)
		if not nb.has_point(pos):
			inside = false
	_ok(inside, "the ports sit on the placed assembly")
	_ok(handles.get("res_in_0", "") == "biomass" and handles.get("res_out_2", "") == "woodgas", "feed → the biomass input, woodgas → the woodgas output (%s)" % str(handles))
	_ok(handles.get("res_out_1", "") == "hot_water" and not handles.has("res_out_0"), "warm cooling water → hot water; the char has no pipe")
	var gas := {}
	for q in ports:
		if str(q["resource_kind"]) == "woodgas":
			gas = q
	_ok(not gas.is_empty() and Vector3(float(gas["nx"]), float(gas["ny"]), float(gas["nz"])).dot(Vector3.UP) < 0.9, "the woodgas port faces out of its fitting")
	_ok(ConnectionPortDefs.default_ports_for_model("tclab_biochar_reactor").size() == ports.size(), "the catalog model reports the same ports")
	var unbound := spec.duplicate(true)
	unbound["binds"] = ""
	for q in TcDesign.connection_ports(TcDesign.solve(unbound)):
		if not str(q["handle_id"]).is_empty():
			_ok(false, "an unbound design maps no handles")
			break
	# Packing.
	var ps := TcDesign.packed_spec(d)
	var clamps := 0.0
	for jd in d["res"]["joints"]:
		if str(jd["kind"]) == "tc":
			clamps += TcDesign.clamp_kg(str(jd["size"])) + 0.02
	_ok(not ps.is_empty() and float(ps["mass_kg"]) >= float(d["bom"]["mass_kg"]) + clamps - 0.5, "it packs at its parts' mass or more (%.1f kg)" % float(ps.get("mass_kg", 0.0)))
	_ok(int(ps.get("units", 0)) >= 2, "as more than one handling unit (%d)" % int(ps.get("units", 0)))
	var vessel_kg := 0.0
	for id in d["res"]["order"]:
		if str(d["res"]["parts"][id]["built"]["type"]) == "vessel":
			vessel_kg = float(d["res"]["parts"][id]["built"]["mass_kg"])
	_ok(vessel_kg > PackKitter.ONE_PERSON_KG, "the vessel is more than one person lifts (%.1f kg)" % vessel_kg)
	_near(TcDesign.clamp_kg("2"), 0.25, 0.01, "a 2\" clamp ≈ 0.25 kg (estimate)")
	var inst := ModelCatalog.instantiate("tclab_biochar_reactor", {})
	_ok(inst is TcBuilder and inst.get_node_or_null("Mesh") != null, "ModelCatalog builds the catalog id")
	if inst != null:
		inst.free()


func _test_builder_export() -> void:
	var d := TcDesign.solve(TcPresets.manifold())
	var b := TcBuilder.new()
	b.build(d, {"selected": [str(d["res"]["order"][0])]})
	var parts := 0
	var joints := 0
	for c in b.get_children():
		if c.has_meta("tc_part"):
			parts += 1
		elif c.has_meta("tc_joint"):
			joints += 1
	_ok(parts == (d["res"]["order"] as Array).size(), "a node per part")
	_ok(joints == 4, "a clamp + gasket per clamp joint (%d)" % joints)
	_ok((b.get_child(0) as MeshInstance3D).material_overlay != null, "the selected part is highlighted")
	b.free()
	var tris := TcBuilder.triangles_mm(d)
	var dir := "user://tclab_selftest_tmp"
	var out := TcExport.write_all(d, dir)
	_ok(bool(out["ok"]), "every file written (%s)" % str(out.get("error", "")))
	var stl := "%s/%s.stl" % [dir, dir.get_file()]
	var f := FileAccess.open(stl, FileAccess.READ)
	_ok(f != null and f.get_length() == 84 + 50 * int(tris.size() / 3.0), "the STL holds every triangle")
	if f != null:
		f.close()
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	var err := doc.append_from_file("%s/%s.glb" % [dir, dir.get_file()], st)
	_ok(err == OK and st.get_meshes().size() >= 1, "the GLB reads back with its mesh")
	for fn in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute("%s/%s" % [dir, fn])
	DirAccess.remove_absolute(dir)
