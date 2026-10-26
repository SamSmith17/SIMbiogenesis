extends SceneTree

## Dome & zome designer selftest (offline, deterministic):
##   Godot.exe.exe --headless --path . --script core/domelab/domelab_selftest.gd
## Pins the Goldberg–Coxeter construction against the published chord-factor
## tables (Domebook II / desertdomes: 2V A 0.54653 B 0.61803; 3V A 0.34862
## B 0.40355 C 0.41241; 4V A 0.25318 B 0.29453 C 0.29524 D 0.29859 E 0.31287
## F 0.32492) and the known strut / hub / face counts (2V 1/2: 65 struts,
## 26 hubs, 40 faces; 3V 5/8: 165 / 61 / 105; 4V 1/2: 250 / 91 / 160), Euler
## on every closed surface incl. Class II and III, the polar zonohedron
## (one strut length, n(n−1) rhombi, a level floor, the helix rib through
## its nodes), the connector angles (a sphere's dip = half the central
## angle), the nexorade fit (every slat four holes, slats one thickness
## apart), plates (nine-point flange ring, fold = half the face angle),
## panels nesting, the BOM's stock packing, the packed envelope, the DXF
## round trip through FlatpackCam.dxf_parse, every preset solving without an
## error, and the 3D builder's picking. Carries EXPECTED_CHECKS: a runtime
## error aborts a test function while PASS still prints.

const EXPECTED_CHECKS := 183

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
	print("DomeLab selftest")
	_test_materials()
	_test_spec()
	_test_base_polyhedra()
	_test_class_i_tables()
	_test_class_ii_iii()
	_test_connectors()
	_test_zome()
	_test_nexorade()
	_test_panels_and_plates()
	_test_helical()
	_test_folded_plates()
	_test_bom_and_packing()
	_test_cam()
	_test_presets()
	_test_builder()
	var total := _pass + _fail
	print("DomeLab selftest: %d checks, %d passed, %d failed" % [total, _pass, _fail])
	if total != EXPECTED_CHECKS:
		print("  FAIL: expected %d checks, ran %d (a test function aborted?)" % [EXPECTED_CHECKS, total])
		_fail += 1
	print("RESULT: %s" % ("PASS" if _fail == 0 else "FAIL"))
	quit(0 if _fail == 0 else 1)


func _test_materials() -> void:
	var emt := DomeLabMaterials.strut("emt_34")
	_check("emt 3/4 OD", _approx(float(emt["od_mm"]), 23.4, 0.01))
	_check("gyration tube", _approx(DomeLabMaterials.strut_gyration_mm(emt), 7.84, 0.1),
		str(DomeLabMaterials.strut_gyration_mm(emt)))
	var bolt := DomeLabMaterials.bolt("3_8")
	_check("bolt length rounds up", DomeLabMaterials.bolt_length_mm(bolt, 40.0) == 51)
	_check("bolt length past the table", DomeLabMaterials.bolt_length_mm(bolt, 500.0) == 152)
	_check("flattened stack is two walls", _approx(DomeLabMaterials.strut_stack_mm(emt, true), 2.9, 0.01))
	_check("sheet order covers table", DomeLabMaterials.SHEET_ORDER.size() == DomeLabMaterials.SHEETS.size())
	_check("strut order covers table", DomeLabMaterials.STRUT_ORDER.size() == DomeLabMaterials.STRUTS.size())


func _test_spec() -> void:
	var s := DomeLabSpec.resolve({"family": "bogus", "radius_m": 999.0, "geodesic": {"frequency": 40, "cls": 2},
		"system": "nope", "colors": {"strut": [1, 0, 0]}})
	_check("family falls back", str(s["family"]) == "geodesic")
	_check("radius clamps", _approx(float(s["radius_m"]), DomeLabSpec.MAX_RADIUS_M, 1e-9))
	_check("frequency clamps", int(s["geodesic"]["frequency"]) == 10)
	_check("system falls back", str(s["system"]) == "bolt_stack")
	_check("colour from array", (s["colors"]["strut"] as Color).is_equal_approx(Color(1, 0, 0)))
	var js := DomeLabSpec.to_json_safe(s)
	_check("json-safe colours are arrays", js["colors"]["strut"] is Array)
	var back := DomeLabSpec.resolve(js)
	_check("json round trip", DomeLabSpec.key_of(back) == DomeLabSpec.key_of(s))
	_check("plate forces a sheet", str(DomeLabSpec.resolve({"system": "plate"})["face"]["material"]) != "none")
	_check("describe", DomeLabSpec.describe(DomeLabSpec.default_spec()).contains("3V"))


func _test_base_polyhedra() -> void:
	for pair in [["icosa", 12, 20], ["octa", 6, 8], ["tetra", 4, 4]]:
		var p := DomeLabGeodesic.base_polyhedron(str(pair[0]))
		_check("%s counts" % str(pair[0]), (p["verts"] as PackedVector3Array).size() == int(pair[1])
			and (p["faces"] as Array).size() == int(pair[2]))
		var ok := true
		for v in (p["verts"] as PackedVector3Array):
			ok = ok and _approx(v.length(), 1.0, 1e-5)
		_check("%s on the unit sphere" % str(pair[0]), ok)
		var e := DomeLabGeodesic._edges_of(p["faces"])
		_check("%s Euler" % str(pair[0]), (p["verts"] as PackedVector3Array).size() - e.size() + (p["faces"] as Array).size() == 2)


func _geo(freq: int, fraction: float, flat: bool = false, cls: int = 1, base: String = "icosa") -> Dictionary:
	return DomeLabGeodesic.build({"base": base, "cls": cls, "frequency": freq, "fraction": fraction,
		"flat_base": flat, "orientation": "vertex", "stretch": 1.0}, 1.0)


func _factors(geo: Dictionary) -> Array:
	var verts: PackedVector3Array = geo["verts"]
	var lens := {}
	for e in geo["edges"]:
		var L := verts[int(e[0])].distance_to(verts[int(e[1])])
		var key := int(round(L * 1e4))
		lens[key] = L
	var out := lens.values()
	out.sort()
	return out


func _test_class_i_tables() -> void:
	var g2 := _geo(2, 1.0)
	var fc: Dictionary = g2["full_count"]
	_check("2V sphere V/E/F", int(fc["v"]) == 42 and int(fc["e"]) == 120 and int(fc["f"]) == 80, str(fc))
	var f2 := _factors(g2)
	_check("2V two chord factors", f2.size() == 2, str(f2))
	_check("2V A 0.54653", f2.size() == 2 and _approx(float(f2[0]), 0.54653, 2e-5), str(f2))
	_check("2V B 0.61803", f2.size() == 2 and _approx(float(f2[1]), 0.61803, 2e-5), str(f2))
	var h2 := _geo(2, 0.5)
	_check("2V hemisphere 65 struts", (h2["edges"] as Array).size() == 65, str((h2["edges"] as Array).size()))
	_check("2V hemisphere 26 hubs", (h2["verts"] as PackedVector3Array).size() == 26)
	_check("2V hemisphere 40 faces", (h2["faces"] as Array).size() == 40)
	_check("2V hemisphere 10 base hubs", (h2["base_ids"] as Array).size() == 10, str((h2["base_ids"] as Array).size()))
	var g3 := _geo(3, 0.625)
	var f3 := _factors(g3)
	_check("3V three chord factors", f3.size() == 3, str(f3))
	_check("3V A 0.34862", f3.size() == 3 and _approx(float(f3[0]), 0.34862, 2e-5), str(f3))
	_check("3V B 0.40355", f3.size() == 3 and _approx(float(f3[1]), 0.40355, 2e-5), str(f3))
	_check("3V C 0.41241", f3.size() == 3 and _approx(float(f3[2]), 0.41241, 2e-5), str(f3))
	_check("3V 5/8 165 struts", (g3["edges"] as Array).size() == 165, str((g3["edges"] as Array).size()))
	_check("3V 5/8 61 hubs", (g3["verts"] as PackedVector3Array).size() == 61, str((g3["verts"] as PackedVector3Array).size()))
	_check("3V 5/8 105 faces", (g3["faces"] as Array).size() == 105, str((g3["faces"] as Array).size()))
	# The 3V 5/8 base is two heights; flattening makes it one and adds lengths.
	var verts3: PackedVector3Array = g3["verts"]
	var lo := INF
	var hi := -INF
	for id in g3["base_ids"]:
		lo = minf(lo, verts3[int(id)].y)
		hi = maxf(hi, verts3[int(id)].y)
	_check("3V 5/8 base is not level", hi - lo > 0.005 and hi - lo < 0.05, "%f" % (hi - lo))
	var g3f := _geo(3, 0.625, true)
	var vf: PackedVector3Array = g3f["verts"]
	var lvl := true
	for id in g3f["base_ids"]:
		lvl = lvl and absf(vf[int(id)].y) < 1e-5
	_check("flat base is level at y 0", lvl)
	_check("flat base adds strut lengths", _factors(g3f).size() > 3, str(_factors(g3f).size()))
	var g4 := _geo(4, 0.5)
	var f4 := _factors(g4)
	var want4 := [0.25318, 0.29453, 0.29524, 0.29859, 0.31287, 0.32492]
	_check("4V six chord factors", f4.size() == 6, str(f4))
	var ok4 := f4.size() == 6
	for i in mini(f4.size(), 6):
		ok4 = ok4 and _approx(float(f4[i]), float(want4[i]), 2e-5)
	_check("4V table", ok4, str(f4))
	_check("4V 1/2 250 struts", (g4["edges"] as Array).size() == 250, str((g4["edges"] as Array).size()))
	_check("4V 1/2 91 hubs", (g4["verts"] as PackedVector3Array).size() == 91)
	_check("4V 1/2 160 faces", (g4["faces"] as Array).size() == 160)
	_check("4V fraction actual 1/2", _approx(float(g4["fraction_actual"]), 0.5, 1e-6), str(g4["fraction_actual"]))
	# Stretch keeps the topology and changes the lengths.
	var gs := DomeLabGeodesic.build({"base": "icosa", "cls": 1, "frequency": 2, "fraction": 0.5, "stretch": 0.7}, 1.0)
	_check("stretched 2V keeps 65 struts", (gs["edges"] as Array).size() == 65)
	_check("stretched 2V has more lengths", _factors(gs).size() > 2)
	var go := _geo(2, 0.5, false, 1, "octa")
	_check("octa 2V hemisphere", (go["faces"] as Array).size() == 16 and (go["base_ids"] as Array).size() == 8,
		"%d faces %d base" % [(go["faces"] as Array).size(), (go["base_ids"] as Array).size()])


func _test_class_ii_iii() -> void:
	var g := _geo(4, 1.0, false, 2)
	var fc: Dictionary = g["full_count"]
	_check("4V class II T = 12", int(g["T"]) == 12)
	_check("4V class II 240 faces", int(fc["f"]) == 240, str(fc))
	_check("4V class II Euler", int(fc["v"]) - int(fc["e"]) + int(fc["f"]) == 2, str(fc))
	_check("4V class II 122 vertices", int(fc["v"]) == 122, str(fc))
	var h := DomeLabGeodesic.build({"base": "icosa", "cls": 2, "frequency": 4, "fraction": 0.5, "orientation": "edge",
		"flat_base": false}, 1.0)
	# Every icosahedral mirror plane holds two icosa edges, which Class II
	# straddles: 8 ties are trimmed, 116 whole faces stay (not 120).
	_check("4V class II hemisphere (edge up) trims the 8 straddlers", (h["faces"] as Array).size() == 116, str((h["faces"] as Array).size()))
	var g3 := DomeLabGeodesic.build({"base": "icosa", "cls": 3, "b": 2, "c": 1, "fraction": 1.0}, 1.0)
	var fc3: Dictionary = g3["full_count"]
	_check("(2,1) class III T = 7", int(g3["T"]) == 7)
	_check("(2,1) class III 140 faces", int(fc3["f"]) == 140, str(fc3))
	_check("(2,1) class III Euler", int(fc3["v"]) - int(fc3["e"]) + int(fc3["f"]) == 2, str(fc3))
	var g6 := _geo(6, 1.0, false, 2)
	_check("6V class II 540 faces", int(g6["full_count"]["f"]) == 540, str(g6["full_count"]))
	# Every edge of a closed surface is shared by exactly two faces.
	var fidx := DomeLabConnectors.face_index(g3)
	var two := true
	for key in fidx["by_edge"]:
		two = two and ((fidx["by_edge"] as Dictionary)[key] as Array).size() == 2
	_check("class III every edge in two faces", two)


func _test_connectors() -> void:
	var spec := DomeLabSpec.default_spec()
	spec["geodesic"]["frequency"] = 2
	spec["geodesic"]["fraction"] = 0.5
	spec["geodesic"]["flat_base"] = false
	spec["radius_m"] = 1.0
	var d := DomeLabDesign.solve(spec)
	var edges: Array = d["edges"]
	# On a sphere the dip is half the central angle: asin(L / 2R).
	var worst := 0.0
	for e in edges:
		var want := asin(float(e["len"]) * 0.5)
		worst = maxf(worst, absf(float(e["dip_a"]) - want))
		worst = maxf(worst, absf(float(e["dip_b"]) - want))
	_check("sphere dip = half central angle", worst < deg_to_rad(0.3), "%f deg" % rad_to_deg(worst))
	_check("2V hubs: 5-way and 6-way", (d["hub_types"] as Array).size() >= 2)
	var maxv := 0
	var minv := 99
	for h in d["hubs"]:
		maxv = maxi(maxv, int(h["valence"]))
		minv = mini(minv, int(h["valence"]))
	_check("valence 4 (base) … 6", minv == 4 and maxv == 6, "%d..%d" % [minv, maxv])
	var fans: Array = d["fans"]
	var sorted_ok := true
	for v in fans.size():
		var fan: Array = fans[v]
		var prev := -INF
		for ei in fan:
			var e: Dictionary = edges[int(ei)]
			var az := float(e["az_a"] if int(e["a"]) == v else e["az_b"])
			sorted_ok = sorted_ok and az >= prev - 1e-9
			prev = az
	_check("fans sorted by azimuth", sorted_ok)
	# Bolt stack: cut = chord + 2 × hole offset; bends = dips.
	var c0: Dictionary = d["strut_classes"][0]
	_check("conduit cut = hole + 2 offsets", _approx(float(c0["cut"]), float(c0["hole_len"]) + 0.05, 1e-6))
	_check("conduit bend is the dip", _approx(float(c0["bend_b"]), rad_to_deg(asin(float(c0["len"]) * 0.5)), 0.3), str(c0))
	# Dihedral: two faces of a 2V sphere are far from coplanar.
	var bend := 0.0
	for e in edges:
		bend = maxf(bend, float(e["flange_bend"]))
	_check("flange bend between 5° and 25°", bend > deg_to_rad(5.0) and bend < deg_to_rad(25.0), "%f" % rad_to_deg(bend))
	# Flat bar: arc > chord, strain = t / 2R.
	var fb := spec.duplicate(true)
	fb["system"] = "flat_bar"
	fb["strut"]["material"] = "hdpe_bar_50x6"
	var df := DomeLabDesign.solve(fb)
	var cf: Dictionary = df["strut_classes"][0]
	_check("flat bar arc longer than chord", float(cf["arc_len"]) > float(cf["len"]) * 1.005)
	_check("flat bar bend radius ≈ R", _approx(float(cf["bend_radius"]), 1.0, 0.03), str(cf["bend_radius"]))
	_check("flat bar strain = t / 2R", _approx(float(cf["strain"]), 0.006 / 2.0, 1e-4), str(cf["strain"]))
	# Socket hubs: cut = chord − 2 × reach.
	var hb := spec.duplicate(true)
	hb["system"] = "hub"
	hb["hub"]["kind"] = "socket"
	hb["hub"]["reach_mm"] = 60.0
	var dh := DomeLabDesign.solve(hb)
	var ch: Dictionary = dh["strut_classes"][0]
	_check("socket cut = chord − 2 reach", _approx(float(ch["cut"]), float(ch["len"]) - 0.12, 1e-6))
	_check("bolts: one per hub on a conduit dome", int(d["bolts"]["count"]) == 26, str(d["bolts"]["count"]))
	_check("build order starts at the base", float((d["order"] as Array)[0]["y"]) < 0.05
		and (d["order"] as Array).size() >= 3)


func _test_zome() -> void:
	var n := 8
	var z := DomeLabZome.build({"sides": n, "layers": 4, "pitch_deg": 40.0, "base": "cut", "triangulate": false,
		"stretch": 1.0}, 3.0)
	var verts: PackedVector3Array = z["verts"]
	_check("8-zome 4 layers: 33 vertices", verts.size() == 33, str(verts.size()))
	_check("8-zome faces 24 rhombi + 8 triangles", (z["faces"] as Array).size() == 32, str((z["faces"] as Array).size()))
	_check("8-zome full surface n(n−1) rhombi", int(z["full_count"]["f"]) == n * (n - 1))
	var base: Array = z["base_ids"]
	_check("8-zome octagon floor", base.size() == 8)
	var lvl := true
	for id in base:
		lvl = lvl and absf(verts[int(id)].y) < 1e-5
	_check("8-zome floor is level at y 0", lvl)
	# One generator length: every non-base edge the same.
	var gen_len := float(z["gen_len_m"])
	var same := true
	var tags: Dictionary = z["edge_tags"]
	for e in z["edges"]:
		var key := DomeLabGeodesic._ekey(int(e[0]), int(e[1]))
		var fam := str((tags.get(key, {}) as Dictionary).get("rib", ""))
		var L := verts[int(e[0])].distance_to(verts[int(e[1])])
		if fam == "R" or fam == "L":
			same = same and _approx(L, gen_len, 1e-5)
	_check("every rib edge is one generator long", same)
	_check("generator length R sin(π/n) / sin θ", _approx(gen_len, 3.0 * sin(PI / n) / sin(deg_to_rad(40.0)), 1e-6))
	var rmax := 0.0
	for v in verts:
		rmax = maxf(rmax, Vector2(v.x, v.z).length())
	_check("widest ring at the radius", _approx(rmax, 3.0, 1e-4), str(rmax))
	var apex := 0
	for i in verts.size():
		if verts[i].y > verts[apex].y:
			apex = i
	_check("apex on the axis", Vector2(verts[apex].x, verts[apex].z).length() < 1e-5)
	# The helix rib passes through its nodes.
	var rib_index: Dictionary = z["rib_index"]
	var worst := 0.0
	var seen := 0
	for e in z["edges"]:
		var key := DomeLabGeodesic._ekey(int(e[0]), int(e[1]))
		var tag: Dictionary = tags.get(key, {})
		if str(tag.get("rib", "")) != "R" and str(tag.get("rib", "")) != "L":
			continue
		for vid in [int(e[0]), int(e[1])]:
			var ik: Vector2i = rib_index[vid]
			var p := DomeLabZome.rib_point(z, str(tag["rib"]), int(tag["index"]), float(ik.y))
			worst = maxf(worst, p.distance_to(verts[vid]))
			seen += 1
	_check("rib curve through its nodes", worst < 2e-4 and seen > 0, "%f over %d" % [worst, seen])
	_check("rib arc longer than its chord", DomeLabZome.rib_arc_length(z, "R", 0, 1.0, 2.0) > gen_len)
	# Zigzag base keeps whole rhombi; triangulate doubles the faces.
	var zz := DomeLabZome.build({"sides": n, "layers": 4, "pitch_deg": 40.0, "base": "zigzag"}, 3.0)
	_check("zigzag base: 32 rhombi, 16 base hubs", (zz["faces"] as Array).size() == 32 and (zz["base_ids"] as Array).size() == 16,
		"%d faces %d base" % [(zz["faces"] as Array).size(), (zz["base_ids"] as Array).size()])
	var zt := DomeLabZome.build({"sides": n, "layers": 4, "pitch_deg": 40.0, "base": "cut", "triangulate": true}, 3.0)
	_check("triangulated: 56 faces", (zt["faces"] as Array).size() == 56, str((zt["faces"] as Array).size()))
	# Through the design: socket hubs give one generator class + the base.
	var spec := DomeLabSpec.default_spec("zome")
	spec["zome"]["sides"] = n
	spec["zome"]["layers"] = 4
	spec["system"] = "hub"
	spec["hub"]["kind"] = "socket"
	spec["face"]["material"] = "none"
	var d := DomeLabDesign.solve(spec)
	_check("zome socket hubs: two strut classes", (d["strut_classes"] as Array).size() == 2, str((d["strut_classes"] as Array).size()))
	_check("zome rhombus warning without panels", (d["checks"] as Array).any(func(c): return str(c["text"]).contains("mechanism")))
	# Ribs mode.
	spec["zome"]["ribs"] = true
	spec["strut"]["material"] = "ply_rib_18x90"
	var dr := DomeLabDesign.solve(spec)
	_check("helix ribs: 2n ribs", (dr["ribs"] as Array).size() == 2 * n, str((dr["ribs"] as Array).size()))
	_check("helix ribs: no straight struts", (dr["struts"] as Array).is_empty())
	var rib0: Dictionary = dr["ribs"][0]
	_check("rib notches between segments", (rib0["notches"] as Array).size() == (rib0["segs"] as Array).size() - 1)
	_check("helix ribs one class by symmetry", (dr["rib_classes"] as Array).size() <= 2, str((dr["rib_classes"] as Array).size()))


func _test_nexorade() -> void:
	var spec := DomeLabSpec.default_spec()
	spec["geodesic"]["frequency"] = 2
	spec["geodesic"]["fraction"] = 0.5
	spec["geodesic"]["flat_base"] = false
	spec["radius_m"] = 3.0
	spec["system"] = "nexorade"
	spec["nexorade"]["slat"] = "hdpe_bar_50x6"
	var d := DomeLabDesign.solve(spec)
	var nx: Dictionary = d["nexorade"]
	var nexors: Array = nx["nexors"]
	_check("one slat per edge", nexors.size() == 65, str(nexors.size()))
	var four := true
	var longer := true
	var base_set := {}
	for id in d["geo"]["base_ids"]:
		base_set[int(id)] = true
	for n in nexors:
		var e: Dictionary = d["edges"][int(n["edge"])]
		if base_set.has(int(e["a"])) or base_set.has(int(e["b"])):
			continue   # the base ring has no neighbours below to rest on
		four = four and (n["holes"] as Array).size() == 4
		longer = longer and float(n["len"]) > float(e["len"])
	_check("every inner slat has four holes", four)
	_check("every inner slat longer than its edge", longer)
	_check("band auto engagement fits the length", _approx(float(nx["engage_frac"]), 0.22, 0.02), str(nx["engage_frac"]))
	_check("engagement angle sensible", float(nx["rho_deg"]) > 5.0 and float(nx["rho_deg"]) < 35.0, str(nx["rho_deg"]))
	_check("bands measured along the arc", float(nexors[0]["arc_scale"]) > 1.005, str(nexors[0]["arc_scale"]))
	spec["nexorade"]["mode"] = "rigid"
	var drg := DomeLabDesign.solve(spec)
	_check("rigid auto engagement fits the thickness", _approx(float(drg["nexorade"]["mean_ecc_mm"]), 6.0, 1.5), str(drg["nexorade"]["mean_ecc_mm"]))
	spec["nexorade"]["mode"] = "band"
	_check("crossings = Σ valence", int(nx["crossings"]) == 130, str(nx["crossings"]))
	_check("few slat classes (A, B and the base variants)", (nx["classes"] as Array).size() <= 8, str((nx["classes"] as Array).size()))
	_check("no struts / hubs drawn", (d["struts"] as Array).is_empty())
	# Manual engagement is honoured and eccentricity grows with it.
	spec["nexorade"]["engagement_deg"] = 5.0
	var d5 := DomeLabDesign.solve(spec)
	spec["nexorade"]["engagement_deg"] = 10.0
	var d10 := DomeLabDesign.solve(spec)
	_check("manual engagement kept", _approx(float(d5["nexorade"]["rho_deg"]), 5.0, 1e-9))
	_check("eccentricity grows with engagement", float(d10["nexorade"]["mean_ecc_mm"]) > float(d5["nexorade"]["mean_ecc_mm"]))


func _test_panels_and_plates() -> void:
	var spec := DomeLabSpec.default_spec()
	spec["geodesic"]["frequency"] = 3
	spec["geodesic"]["fraction"] = 0.625
	spec["radius_m"] = 2.5
	spec["face"]["material"] = "polycarb_6"
	var d := DomeLabDesign.solve(spec)
	var pn: Dictionary = d["panels"]
	_check("a panel per face", (pn["panels"] as Array).size() == 105, str((pn["panels"] as Array).size()))
	_check("panels nest on sheets", int(pn["sheets"]) > 0 and (pn["unplaced"] as Array).is_empty(),
		"%d sheets %d unplaced" % [int(pn["sheets"]), (pn["unplaced"] as Array).size()])
	_check("panel classes few", (pn["classes"] as Array).size() <= 12, str((pn["classes"] as Array).size()))
	var p0: Dictionary = pn["panels"][0]
	_check("covered panel: three corners", (p0["outer"] as PackedVector2Array).size() == 3)
	_check("covered panel has screw holes", (p0["holes"] as Array).size() >= 6)
	_check("panel area ~0.59 of the sphere", float(pn["area_m2"]) > 40.0 and float(pn["area_m2"]) < 50.0, str(pn["area_m2"]))
	# Plates.
	var ps := DomeLabSpec.default_spec()
	ps["geodesic"]["frequency"] = 2
	ps["geodesic"]["fraction"] = 0.5
	ps["geodesic"]["flat_base"] = false
	ps["radius_m"] = 1.8
	ps["system"] = "plate"
	ps["face"]["material"] = "alu_1"
	var dp := DomeLabDesign.solve(ps)
	var pp: Dictionary = dp["panels"]
	var q0: Dictionary = pp["panels"][0]
	_check("plate ring: nine points (three flanges)", (q0["outer"] as PackedVector2Array).size() == 9)
	_check("plate folds carry the bend", (q0["fold"] as Array).size() == 3 and float((q0["fold"] as Array)[0][2]) > 5.0,
		str(q0["fold"]))
	_check("plate dome has no struts or hubs", (dp["struts"] as Array).is_empty() and (dp["hubs"] as Array).is_empty())
	_check("plate bolts from the flange holes", int(dp["bolts"]["count"]) > 40, str(dp["bolts"]["count"]))
	var content := DomeLabPanels.sheet_content(pp, 0)
	_check("sheet content has folds", (content["fold"] as Array).size() > 0 and (content["outside"] as Array).size() > 0)
	# A hole lies inside its flange, not the face.
	var hole: Dictionary = (q0["holes"] as Array)[0]
	var hp: Vector2 = (hole["pts"] as PackedVector2Array)[0]
	_check("flange hole outside the face polygon", not Geometry2D.is_point_in_polygon(hp, q0["poly"]))


func _test_helical() -> void:
	# The reference build (Helical Zome Corten Steel.glb): 10 sides, 57.1°,
	# 1.585 m struts, 21 cells — 452 nodes, 900 edges, 450 rhombi.
	var ref := DomeLabPresets.helical_corten_spec()
	var whole: Dictionary = ref["helical"].duplicate()
	whole["levels"] = 0
	var g := DomeLabHelical.build(whole, float(ref["radius_m"]))
	var fc: Dictionary = g["full_count"]
	_check("helical reference: 452 / 900 / 450", int(fc["v"]) == 452 and int(fc["e"]) == 900 and int(fc["f"]) == 450, str(fc))
	_check("helical surface is a sphere (χ = 2)", int(fc["v"]) - int(fc["e"]) + int(fc["f"]) == 2)
	var verts: PackedVector3Array = g["verts"]
	var one_len := true
	for e in g["edges"]:
		if absf(verts[int(e[0])].distance_to(verts[int(e[1])]) - 1.585) > 0.001:
			one_len = false
	_check("helical: one strut length (1.585 m)", one_len)
	_check("helical reference: 30 rows, 25.83 m from apex to tip", int(g["levels_total"]) == 30 and _approx(float(g["top_y"]), 25.828, 0.01), str(g["top_y"]))
	# Every face a rhombus whose corner is its zone's angle.
	var zone_ok := true
	var zones := {}
	var faces: Array = g["faces"]
	for fi in faces.size():
		var f: PackedInt32Array = faces[fi]
		var z := int(g["face_zone"][fi])
		zones[z] = true
		var a := rad_to_deg((verts[f[1]] - verts[f[0]]).angle_to(verts[f[3]] - verts[f[0]]))
		a = minf(a, 180.0 - a)
		if f.size() != 4 or absf(a - DomeLabHelical.zone_angle_deg(10, deg_to_rad(57.1), z)) > 0.1:
			zone_ok = false
	_check("helical: rhombi in five zones, angle per zone", zone_ok and zones.size() == 5, str(zones.keys()))
	# Windows w: 3 stacks rhombohedra face to face, n = w = 4 at 54.74° stacks
	# rhombic dodecahedra (every rhombus 70.53°); all close.
	var g3 := DomeLabHelical.build({"sides": 10, "window": 3, "steps": 20, "pitch_deg": 57.1}, 4.3)
	_check("window 3: 86 faces, closed", (g3["faces"] as Array).size() == 86 and int(g3["full_count"]["v"]) - int(g3["full_count"]["e"]) + 86 == 2)
	var grd := DomeLabHelical.build({"sides": 4, "window": 4, "steps": 2, "pitch_deg": 54.7356}, 1.0)
	var rd_ok := (grd["faces"] as Array).size() == 24
	var vr: PackedVector3Array = grd["verts"]
	for f in grd["faces"]:
		var pf: PackedInt32Array = f
		var a := rad_to_deg((vr[pf[1]] - vr[pf[0]]).angle_to(vr[pf[3]] - vr[pf[0]]))
		rd_ok = rd_ok and absf(minf(a, 180.0 - a) - 70.53) < 0.05
	_check("three stacked rhombic dodecahedra: 24 rhombi of 70.53°", rd_ok)
	var closed := true
	for cfg in [[7, 5, 14], [16, 16, 12], [6, 6, 6], [12, 8, 30]]:
		var gc := DomeLabHelical.build({"sides": cfg[0], "window": cfg[1], "steps": cfg[2], "pitch_deg": 50.0}, 2.0)
		var cc: Dictionary = gc["full_count"]
		closed = closed and int(cc["v"]) - int(cc["e"]) + int(cc["f"]) == 2
	_check("every window / length closes (χ = 2)", closed)
	# The floor cut: level, at the person's floor.
	var gk := DomeLabHelical.build(ref["helical"], float(ref["radius_m"]))
	var lvl := true
	for id in gk["base_ids"]:
		lvl = lvl and absf((gk["verts"] as PackedVector3Array)[int(id)].y) < 1e-4
	_check("floor cut at 14 rows: 216 faces, 12.05 m tall, level floor", (gk["faces"] as Array).size() == 216
		and _approx(float(gk["top_y"]), 12.053, 0.01) and lvl and (gk["base_ids"] as Array).size() >= 3)
	# Handedness mirrors the body.
	var left: Dictionary = whole.duplicate()
	left["hand"] = "left"
	var gl := DomeLabHelical.build(left, float(ref["radius_m"]))
	var bx := Vector2(INF, -INF)
	for v in verts:
		bx = Vector2(minf(bx.x, v.x), maxf(bx.y, v.x))
	var lx := Vector2(INF, -INF)
	for v in (gl["verts"] as PackedVector3Array):
		lx = Vector2(minf(lx.x, v.x), maxf(lx.y, v.x))
	_check("left hand mirrors the right", _approx(lx.y, -bx.x, 0.002) and _approx(lx.x, -bx.y, 0.002), "%s %s" % [lx, bx])
	# The design: floor area, BOM, checks.
	var d := DomeLabDesign.solve(ref)
	_check("helical home: ~82 m² floor, ~12.9 m across", float(d["stats"]["floor_area_m2"]) > 70.0
		and float(d["stats"]["floor_area_m2"]) < 95.0 and _approx(float(d["stats"]["radius_max_m"]) * 2.0, 12.9, 0.3),
		"%s %s" % [d["stats"]["floor_area_m2"], d["stats"]["radius_max_m"]])
	var errs: Array = (d["checks"] as Array).filter(func(c): return str(c["level"]) == "error")
	_check("helical home solves clean", errs.is_empty(), str(errs))


func _test_folded_plates() -> void:
	# The section: the flange's outer skin sits gap/2 off the bisector plane,
	# the bend is tangent to the skin, and the outline is a sheet t thick.
	var sec := DomeLabPanels.flange_section(deg_to_rad(30.0), 3.0, 6.0, 4.0, 60.0)
	var m: Vector2 = sec["m"]
	var hole: Vector2 = sec["hole"]
	_check("flange hole on the flange's outer skin", _approx(m.dot(hole), 2.0, 1e-6), str(m.dot(hole)))
	var prof: PackedVector2Array = sec["profile"]
	_check("bend starts on the skin (y = 0) and ends t under it", _approx(prof[0].y, 0.0, 1e-6) and _approx(prof[prof.size() - 1].y, -3.0, 1e-6))
	var area := absf(DomeLabPanels._signed_area(prof))
	var dev := 3.0 * (float(sec["run"]) + (PI * 0.5 + float(sec["a2"])) * (6.0 + 1.5))
	_check("section area = t × developed length", _approx(area, dev, dev * 0.02), "%f %f" % [area, dev])
	# Openings: rounded inset stays inside, roundness 0 is the plain inset.
	var sq := PackedVector2Array([Vector2(0, 0), Vector2(1000, 0), Vector2(1000, 600), Vector2(0, 600)])
	var sharp := DomeLabPanels.rounded_inset(sq, 100.0, 0.0, 0.0)
	var round_ := DomeLabPanels.rounded_inset(sq, 100.0, 1.0, 0.0)
	var inside := true
	for q in round_:
		inside = inside and q.x >= 99.9 and q.x <= 900.1 and q.y >= 99.9 and q.y <= 500.1
	_check("opening: sharp = inset, round stays inside", sharp.size() == 4 and round_.size() > 12 and inside
		and absf(DomeLabPanels._signed_area(round_)) < absf(DomeLabPanels._signed_area(sharp)))
	# The reference build's plates: windows in zones 1-2 only, panes on them,
	# holes per edge so the two plates of every seam are drilled alike.
	var d := DomeLabDesign.solve(DomeLabPresets.helical_corten_spec())
	var pn: Dictionary = d["panels"]
	var zone_ok := true
	var n_open := 0
	var flange_holes := 0
	for p in pn["panels"]:
		var has := not (p["oculus"] as PackedVector2Array).is_empty()
		if has:
			n_open += 1
		zone_ok = zone_ok and has == (int(p["zone"]) <= 2)
		flange_holes += (p["holes"] as Array).size() - (1 if has else 0)
	_check("openings only in the 30° and 59° rhombi, all glazed", zone_ok and n_open == int(pn["panes"]) and n_open > 50, str(n_open))
	_check("every flange hole is a bolt or a floor anchor (shared per edge)",
		flange_holes == 2 * (pn["bolts3d"] as Array).size() + int(pn["anchors"]), "%d vs %d" % [flange_holes, 2 * (pn["bolts3d"] as Array).size() + int(pn["anchors"])])
	_check("plate bolt count = the bolts drawn", int(d["bolts"]["count"]) == (pn["bolts3d"] as Array).size())
	# The bolt points lie on the bisector plane of their two faces.
	var on_plane := true
	var verts: PackedVector3Array = d["geo"]["verts"]
	for bt in (pn["bolts3d"] as Array).slice(0, 60):
		var e: Dictionary = d["edges"][int(bt["edge"])]
		var ax: Vector3 = bt["axis"]
		on_plane = on_plane and absf(ax.dot((bt["p"] as Vector3) - verts[int(e["a"])])) < 1e-4
	_check("bolts sit on the plane between the flanges", on_plane)
	# 3D: corten skin, PMMA panes, bolts.
	var node := DomeLabBuilder.build_from_design(d, "Helix", {"record": true})
	var mi := node.get_node("Mesh") as MeshInstance3D
	var kinds := {}
	for si in mi.mesh.get_surface_count():
		var mat := mi.mesh.surface_get_material(si) as StandardMaterial3D
		kinds["glass" if mat.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED else ("corten" if mat.roughness > 0.8 else "metal")] = true
	_check("helical home draws corten, glass and bolts", kinds.size() == 3, str(kinds))
	# Winding: every triangle clockwise seen from where its normals point.
	var wind_ok := true
	for si in mi.mesh.get_surface_count():
		var arr := mi.mesh.surface_get_arrays(si)
		var vv: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var nn: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		for i in range(0, mini(vv.size(), 60000), 3):
			if (vv[i + 1] - vv[i]).cross(vv[i + 2] - vv[i]).dot(nn[i] + nn[i + 1] + nn[i + 2]) > 1e-12:
				wind_ok = false
	_check("folded plates wind clockwise (Godot's front face)", wind_ok)
	node.free()


func _test_bom_and_packing() -> void:
	var spec := DomeLabSpec.default_spec()
	spec["radius_m"] = 4.5
	var d := DomeLabDesign.solve(spec)
	var bom: Dictionary = d["bom"]
	var strut_m := float(bom["strut_m"])
	_check("stock pieces ≥ the metres", int(bom["stock_pieces"]) >= int(ceil(strut_m / 3.048)))
	_check("waste under 40 %", float(bom["waste_pct"]) < 40.0, str(bom["waste_pct"]))
	_check("BOM mass positive", float(bom["mass_kg"]) > 50.0 and float(bom["mass_kg"]) < 400.0, str(bom["mass_kg"]))
	_check("bolts nuts washers", int(bom["bolts"]) == 61 and int(bom["washers"]) == 122, str(bom["bolts"]))
	var pk := DomeLabBom.pack_stock([2.0, 2.0, 1.0, 1.0, 0.9], 3.0, 0.0)
	_check("first-fit decreasing packs 5 cuts into 3", int(pk["pieces"]) == 3, str(pk))
	var ps := DomeLabDesign.packed_spec(d)
	var norm := PackedSpec.normalize(ps)
	_check("packed spec normalizes", not norm.is_empty())
	var longest := 0.0
	for c in d["strut_classes"]:
		longest = maxf(longest, float(c["cut"]))
	_check("bundle as long as the longest strut", _approx(float(norm["w_m"]), longest, 1e-6), str(norm))
	_check("bundle carries the mass", _approx(float(norm["mass_kg"]), float(bom["mass_kg"]), 1e-6))
	# A 3V "5/8" keeps the ring below the equator: really ~0.59 of the sphere.
	_check("stats: 3V 5/8 height ~1.18 R", _approx(float(d["stats"]["height_m"]), 4.5 * 1.177, 0.05), str(d["stats"]["height_m"]))
	_check("stats: floor area", float(d["stats"]["floor_area_m2"]) > 50.0 and float(d["stats"]["floor_area_m2"]) < 75.0,
		str(d["stats"]["floor_area_m2"]))
	_check("chord factor table on the stats", (d["stats"]["chord_factors"] as Dictionary).has("A"))
	var text := DomeLabBom.cut_sheet_text(d)
	_check("cut sheet names struts and hubs", text.contains("STRUTS") and text.contains("HUBS") and text.contains("BUILD ORDER"))
	var csv := DomeLabBom.struts_csv(d)
	_check("struts CSV one row per class", csv.split("\n", false).size() == (d["strut_classes"] as Array).size() + 1)
	var js := DomeLabBom.fabrication_json(d)
	_check("fabrication JSON stringifies", not JSON.stringify(js).is_empty() and (js["struts"] as Array).size() == 165)


func _test_cam() -> void:
	var ps := DomeLabSpec.default_spec()
	ps["geodesic"]["frequency"] = 2
	ps["geodesic"]["fraction"] = 0.5
	ps["radius_m"] = 1.8
	ps["system"] = "plate"
	ps["face"]["material"] = "alu_1"
	ps["name"] = "Selftest plate dome"
	var d := DomeLabDesign.solve(ps)
	var content := DomeLabCam.sheet_content(d, 0)
	var dxf := DomeLabCam.dxf_document(content, "mm")
	var parsed := FlatpackCam.dxf_parse(dxf)
	var polys: Dictionary = parsed["polylines"]
	_check("DXF outside cuts on sheet 1", int(polys.get("OUTSIDE_CUT", 0)) == (content["outside"] as Array).size()
		and int(polys.get("OUTSIDE_CUT", 0)) > 0, str(polys))
	_check("DXF holes", int(polys.get("INSIDE_CUT", 0)) == (content["inside"] as Array).size())
	_check("DXF fold lines present", dxf.contains("FOLD") and dxf.count("\nLINE\n") >= (content["fold"] as Array).size())
	var svg := DomeLabCam.svg_document(content, "mm", "t")
	_check("SVG sized in mm with folds", svg.contains("mm\"") and svg.contains("id=\"FOLD\""))
	var svg_in := DomeLabCam.svg_document(content, "in", "t")
	_check("SVG inches", svg_in.contains("in\""))
	# Hub template and strut end.
	var hs := DomeLabSpec.default_spec()
	hs["system"] = "hub"
	hs["hub"]["kind"] = "plate"
	var dh := DomeLabDesign.solve(hs)
	var ht := DomeLabCam.hub_template(dh, dh["hub_types"][0])
	_check("hub template: disc + centre + arms", (ht["inside"] as Array).size() == int(dh["hub_types"][0]["valence"]) + 1)
	var dc := DomeLabDesign.solve(DomeLabSpec.default_spec())
	var se := DomeLabCam.strut_end_template(dc, dc["strut_classes"][0])
	_check("strut end template has a hole and a bend line", (se["inside"] as Array).size() == 1 and (se["fold"] as Array).size() == 1)
	# write_all to a scratch folder.
	var dir := OS.get_temp_dir().path_join("domelab_selftest_%d" % Time.get_ticks_usec())
	var r := DomeLabCam.write_all(d, dir)
	_check("write_all ok", bool(r["ok"]), str(r))
	var files: Array = r["files"]
	var has := {"dxf": 0, "svg": 0, "csv": 0, "json": 0, "txt": 0}
	for f in files:
		var ext := str(f).get_extension()
		has[ext] = int(has.get(ext, 0)) + 1
	_check("write_all: dxf, svg, 2 csv, json, txt", int(has["dxf"]) >= 1 and int(has["svg"]) >= 1 and int(has["csv"]) == 2
		and int(has["json"]) == 1 and int(has["txt"]) == 1, str(has))
	for f in files:
		DirAccess.remove_absolute(str(f))
	DirAccess.remove_absolute(dir)
	_check("scratch folder removed", not DirAccess.dir_exists_absolute(dir))


func _test_presets() -> void:
	var bi := DomeLabPresets.builtins()
	_check("sixteen built-in designs", bi.size() == 16, str(bi.size()))
	var all_ok := true
	var names := {}
	for p in bi:
		var d := DomeLabDesign.solve(p["spec"])
		var errs: Array = (d["checks"] as Array).filter(func(c): return str(c["level"]) == "error")
		if not errs.is_empty():
			all_ok = false
			print("  preset %s errors: %s" % [str(p["id"]), str(errs)])
		names[str(p["id"])] = true
	_check("every preset solves without an error", all_ok)
	_check("preset ids unique", names.size() == bi.size())
	_check("builtin lookup", not DomeLabPresets.builtin("3v_58").is_empty() and DomeLabPresets.builtin("nope").is_empty())
	var path := OS.get_temp_dir().path_join("domelab_lib_%d.json" % Time.get_ticks_usec())
	_check("library saves", DomeLabPresets.save_library([{"id": "x", "name": "X", "spec": DomeLabSpec.default_spec()}], path))
	var lib := DomeLabPresets.load_library(path)
	_check("library loads", lib.size() == 1 and str(lib[0]["name"]) == "X")
	DirAccess.remove_absolute(path)


func _test_builder() -> void:
	var spec := DomeLabSpec.default_spec()
	spec["geodesic"]["frequency"] = 2
	spec["geodesic"]["fraction"] = 0.5
	spec["radius_m"] = 3.0
	var d := DomeLabDesign.solve(spec)
	var node := DomeLabBuilder.build_from_design(d, "Dome", {"record": true})
	var mi := node.get_node_or_null("Mesh") as MeshInstance3D
	_check("builder: a Mesh child", mi != null and mi.mesh != null)
	_check("builder: strut + hub surfaces", mi != null and mi.mesh.get_surface_count() >= 2, str(mi.mesh.get_surface_count() if mi else -1))
	var picks: Array = node.get_meta("picks", [])
	_check("builder records picks", picks.size() == 65 + 26, str(picks.size()))
	# A ray at a strut's midpoint picks that strut.
	var e: Dictionary = d["edges"][0]
	var mid: Vector3 = e["mid"]
	var origin := mid + mid.normalized() * 2.0 + Vector3(0, 1, 0)
	var hit := DomeLabBuilder.pick(node, origin, (mid - origin).normalized())
	_check("pick a strut by its midpoint", str(hit.get("kind", "")) == "strut" and int(hit.get("edge", -1)) == 0, str(hit))
	var size: Vector3 = node.get_meta("size_m")
	_check("size meta ≈ 6 × 3 × 6", _approx(size.x, 6.0, 0.05) and _approx(size.y, 3.0, 0.1), str(size))
	# Exploded / half-built variants build without error.
	var half := DomeLabBuilder.build_from_design(d, "Half", {"assembly": 0.4, "explode": 0.5, "record": true})
	var hp: Array = half.get_meta("picks", [])
	_check("assembly scrub hides the upper rings", hp.size() > 0 and hp.size() < picks.size(), str(hp.size()))
	# Every family / system builds a mesh.
	var ok := true
	for p in DomeLabPresets.builtins():
		var n := DomeLabBuilder.build_node(p["spec"], "P")
		var m := n.get_node_or_null("Mesh") as MeshInstance3D
		ok = ok and m != null and m.mesh.get_surface_count() > 0
		n.free()
	_check("every preset builds a mesh", ok)
	# The look: a tube shades ROUND (radial normals that differ across a
	# wall triangle) while a flat slab keeps one normal per face — nothing
	# is smoothed across edges, which is what made every dome a bubble.
	var strut_arrays: Array = mi.mesh.surface_get_arrays(0)
	var sn: PackedVector3Array = strut_arrays[Mesh.ARRAY_NORMAL]
	var round_tube := false
	for i in range(0, mini(sn.size(), 600), 3):
		if sn[i].distance_to(sn[i + 2]) > 0.3:
			round_tube = true
			break
	_check("builder: a conduit tube shades round", round_tube)
	# A folded plate: its skin is flat (one normal per triangle) and its
	# bends shade round (the normals differ across a bend triangle).
	var plate := DomeLabBuilder.build_node(DomeLabPresets.builtin("plate_dome")["spec"], "Plate")
	var pmi := plate.get_node_or_null("Mesh") as MeshInstance3D
	var pn := PackedVector3Array()
	for si in pmi.mesh.get_surface_count():
		var mat := pmi.mesh.surface_get_material(si) as StandardMaterial3D
		if mat != null and mat.metallic > 0.7:   # the aluminium sheet, not the bolts
			pn = (pmi.mesh.surface_get_arrays(si) as Array)[Mesh.ARRAY_NORMAL]
	var flat_tris := 0
	var round_tris := 0
	for i in range(0, pn.size(), 3):
		if pn[i].distance_to(pn[i + 1]) > 1e-3 or pn[i].distance_to(pn[i + 2]) > 1e-3:
			round_tris += 1
		else:
			flat_tris += 1
	_check("builder: a plate's skin is flat and its bends round", flat_tris > 100 and round_tris > 100,
		"%d flat, %d round" % [flat_tris, round_tris])
	plate.free()
	# Finishes follow the stock: galvanised conduit, matte tarp, clear glazing.
	var strut_m := mi.mesh.surface_get_material(0) as StandardMaterial3D
	_check("conduit draws as galvanised steel", strut_m != null and strut_m.metallic > 0.5 and strut_m.roughness > 0.4, str(strut_m))
	var tarp := spec.duplicate(true)
	tarp["face"]["material"] = "tarp_pe"
	var tm := DomeLabBuilder._material_for("panel", DomeLabDesign.solve(tarp), false) as StandardMaterial3D
	_check("a tarp is matte and translucent", tm.roughness > 0.9 and tm.metallic < 0.01 and tm.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED, str(tm))
	var glz := spec.duplicate(true)
	glz["face"]["material"] = "polycarb_4"
	var gm := DomeLabBuilder._material_for("panel", DomeLabDesign.solve(glz), false) as StandardMaterial3D
	_check("polycarbonate is glossy, clear glazing", gm.roughness < 0.2 and gm.albedo_color.a < 0.9, str(gm))
	node.free()
	half.free()
	_check("packed spec of a nexorade uses the slat", str(DomeLabDesign.packed_spec(
		DomeLabDesign.solve(DomeLabPresets.builtin("rotegrity")["spec"]))["form"]) == "bundle")
