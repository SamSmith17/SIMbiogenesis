extends SceneTree

## Toroid Lab selftest (offline). The torus maths (measures ↔ torus round
## trip), the reference build reproduced from "Overview Toroid
## structure.glb" (numbers measured off the model with
## tools/diag/glb_mesh_table_diag.gd: the rib circle, the four rings, the
## inner column's bearings, the canopy's corners, the panels' span), every
## rib point on the torus, the fittings by kind, the canopy's flat pieces (an
## isometric unfold, one 4' × 8' sheet per half-bay, the bolts), bracing and
## tension lines, the solar summary for the graph, the builder (winding,
## surfaces, picking, explode / assembly), the packed spec, the JSON round
## trip, the fabrication files and every built-in design without an error.
##   Godot --headless --path . --script core/toroidlab/toroidlab_selftest.gd

const EXPECTED_CHECKS := 85

var _checks := 0
var _fails := 0


func _ok(cond: bool, what: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		print("FAIL: ", what)


func _near(a: float, b: float, tol: float, what: String) -> void:
	_ok(absf(a - b) <= tol, "%s (%.4f vs %.4f ± %.4f)" % [what, a, b, tol])


func _initialize() -> void:
	_test_measures()
	_test_reference_frame()
	_test_reference_canopy()
	_test_reference_solar()
	_test_bracing()
	_test_builder()
	_test_spec_and_files()
	_test_builtins()
	print("toroidlab selftest: %d checks, %d failures" % [_checks, _fails])
	if _checks != EXPECTED_CHECKS:
		print("FAIL: ran %d checks, expected %d (a test function aborted?)" % [_checks, EXPECTED_CHECKS])
		_fails += 1
	print("PASS" if _fails == 0 else "FAILED")
	quit(0 if _fails == 0 else 1)


func _test_measures() -> void:
	var t := ToroidLabSpec.torus_from_measures(0.93, 4.03, 3.177, 0.04, 24)
	_ok(not t.is_empty(), "a torus fits the reference measures")
	var m := ToroidLabSpec.measures(t)
	_near(float(m["inner_r_m"]), 0.93, 1e-6, "inner radius round-trips")
	_near(float(m["outer_r_m"]), 4.03, 1e-6, "outer radius round-trips")
	_near(float(m["height_m"]), 3.177, 1e-6, "height round-trips")
	# The fit lands on the minor circle the rib tubes were measured on.
	_near(float(t["minor_r_m"]), 1.825, 0.02, "the minor radius matches the measured rib circle")
	_ok(ToroidLabSpec.torus_from_measures(3.0, 2.0, 2.0, 0.0).is_empty(), "an inner radius past the outer has no torus")


func _test_reference_frame() -> void:
	var d := ToroidLabDesign.solve(ToroidLabPresets.overview_spec())
	var fr: Dictionary = d["frame"]
	var st: Dictionary = d["stats"]
	# Measured: rib circle centre (2.205, 1.352), r 1.825; ribs reach R 4.047
	# (outer surface) and y 3.192 (top surface); the outer ground ring at R
	# 3.472, the inner rings at R 0.92, the crown ring Ø 5.22 at y 3.104.
	_near(float(st["outer_r_m"]) + float(fr["od"]) * 0.5, 4.047, 0.012, "outer surface radius as measured")
	_near(float(st["height_m"]), 3.192, 0.01, "top surface height as measured")
	var rings: Array = fr["rings"]
	_ok(rings.size() == 4, "four rings (outer ground, crown, inner top, inner ground)")
	_near(float(rings[0]["radius_m"]), 3.472, 0.01, "outer ground ring radius")
	_near(float(rings[1]["radius_m"]) * 2.0, 5.219, 0.02, "crown ring diameter")
	_near(float(rings[1]["y"]), 3.104, 0.01, "crown ring height (clamped under the ribs)")
	_ok(not bool(rings[1]["on_node"]), "the crown ring passes under the ribs")
	_near(float(rings[2]["radius_m"]), 0.925, 0.015, "inner top ring radius")
	_near(float(rings[2]["y"]), 2.654, 0.015, "inner top ring height")
	_near(float(rings[3]["radius_m"]), 0.92, 0.02, "inner ground ring radius")
	var counts := {}
	for c in fr["classes"]:
		counts[str(c["kind"])] = int(counts.get(str(c["kind"]), 0)) + int(c["count"])
	_ok(int(counts.get("rib", 0)) == 48, "24 ribs of two arcs each")
	_ok(int(counts.get("inner", 0)) == 10 and int(counts.get("post", 0)) == 0, "ten inner arcs and no straight posts")
	var posted := ToroidLabSpec.resolve(d["spec"])
	posted["ribs"]["inner_posts"] = true
	var pc := 0
	for m in (ToroidLabDesign.solve(posted)["frame"] as Dictionary)["members"]:
		if str(m["kind"]) == "post":
			pc += 1
	_ok(pc == 10, "the centre posts switch on: one beside each inner arc (%d)" % pc)
	var rib_cls := ToroidLabDesign.member_class(d, "A1")
	_near(float(rib_cls["bend_deg"]), 90.0, 0.5, "each rib arc is a quarter circle")
	_near(float(rib_cls["bend_r_m"]), 1.825, 1e-6, "rib arcs bend to the minor radius")
	# The inner column's bearings in the model: arcs at 16, 46, 76, 106, 136,
	# 166, 196, 226, 316, 346° — two left open at 256 and 286.
	var want := [16.2, 46.4, 76.4, 106.4, 136.3, 166.2, 196.0, 226.0, 316.0, 346.0]
	var got: Array = []
	for m in fr["members"]:
		if str(m["kind"]) == "inner":
			got.append(fposmod(ToroidLabFrame.rib_theta(d["spec"]["torus"], int(m["rib"])), 360.0))
	var all_match := got.size() == want.size()
	for w in want:
		var best := 999.0
		for g in got:
			best = minf(best, absf(float(g) - float(w)))
		all_match = all_match and best < 1.2
	_ok(all_match, "inner arcs stand where the model's do (%s)" % str(got))
	# Every rib point lies on the torus.
	var worst := 0.0
	for m in fr["members"]:
		if str(m["kind"]) != "rib" and str(m["kind"]) != "inner":
			continue
		for p in (m["pts"] as PackedVector3Array):
			var rr := Vector2(p.x, p.z).length()
			worst = maxf(worst, absf(Vector2(rr - 2.205, p.y - 1.352).length() - 1.825))
	_ok(worst < 1e-4, "every rib point is on the rib circle (worst %.6f m)" % worst)
	# The reference model's fittings were counted with its straight centre
	# posts (inner_posts, off in the preset since the real build has none).
	var fits: Dictionary = ToroidLabDesign.solve(posted)["bom"]["fittings"]
	_ok(int(fits.get("tee", 0)) == 38, "tees: 24 at the outer ground + 14 at the inner top")
	_ok(int(fits.get("crossover", 0)) == 24, "a crossover clamp where the crown ring meets each rib")
	_ok(int(fits.get("cross5", 0)) == 10 and int(fits.get("cross", 0)) == 10, "inner column fittings (5-way at the top, cross at the ground)")
	_ok(int(fits.get("coupler", 0)) == 32, "couplers: 24 shoulders + 8 crown ring splices")


func _test_reference_canopy() -> void:
	var d := ToroidLabDesign.solve(ToroidLabPresets.overview_spec())
	var cn: Dictionary = d["canopy"]
	_ok((cn["sectors"] as Array).size() == 24, "a canopy sector per bay")
	# Measured corners on a seam: inner (1.35, 2.88), outer (3.73, 2.32); mid
	# bay: peak (2.67, 3.05), valleys (1.63, 2.41) and (3.45, 2.11).
	var h: Dictionary = cn["sectors"][0]["halves"][0]
	var rz := func(p: Vector3) -> Vector2: return Vector2(Vector2(p.x, p.z).length(), p.y)
	_ok((rz.call(h["A"]) as Vector2).distance_to(Vector2(1.35, 2.88)) < 0.02, "inner corner where the model's is")
	_ok((rz.call(h["B"]) as Vector2).distance_to(Vector2(3.73, 2.32)) < 0.02, "outer corner where the model's is")
	_ok((rz.call(h["P"]) as Vector2).distance_to(Vector2(2.67, 3.05)) < 0.02, "the peak where the model's is")
	_ok((rz.call(h["Vi"]) as Vector2).distance_to(Vector2(1.63, 2.41)) < 0.03, "the inner valley where the model's is")
	_ok((rz.call(h["Vo"]) as Vector2).distance_to(Vector2(3.45, 2.11)) < 0.03, "the outer valley where the model's is")
	var pcs: Array = cn["pieces"]
	_ok(pcs.size() == 2, "two piece shapes (one of each hand)")
	var p0: Dictionary = pcs[0]
	_ok(float(p0["len_ab_mm"]) <= 2440.0 and float(p0["len_ab_mm"]) > 2400.0, "the seam is just under 8 ft (%.1f mm)" % float(p0["len_ab_mm"]))
	# An isometric unfold: the flat area is the three triangles + the flange.
	var a3 := 0.0
	for tri in h["tris"]:
		a3 += ((tri[1] - tri[0]) as Vector3).cross(tri[2] - tri[0]).length() * 0.5
	var fl_w := float(d["spec"]["canopy"]["flange_mm"]) * 0.001
	var L := float(p0["len_ab_mm"]) * 0.001
	var flange := (L + (L - 2.0 * minf(fl_w, L * 0.25))) * 0.5 * fl_w
	_near(float(p0["area_m2"]), a3 + flange, 0.002, "the flat piece has the folded area")
	_ok(int(d["bom"]["sheets"]) == 48, "one 4' × 8' sheet per half-bay (48)")
	_ok(((cn["nest"] as Dictionary).get("unplaced", []) as Array).is_empty(), "every piece nests")
	_ok(int(cn["bolts"]) == 144, "three bolts a seam (144)")
	var folds: Array = p0["fold"]
	_ok(folds.size() == 3 and str(folds[0][3]) == "flange", "a flange fold and two score lines")
	var c := ToroidLabCanopy.sheet_content(cn, 0)
	_ok((c["outside"] as Array).size() >= 1 and (c["fold"] as Array).size() >= 3 and (c["inside"] as Array).size() == 3,
		"a sheet carries its outline, three bolt holes and the score lines")


func _test_reference_solar() -> void:
	var d := ToroidLabDesign.solve(ToroidLabPresets.overview_spec())
	var so: Dictionary = d["solar"]
	var sm: Dictionary = so["summary"]
	_ok(int(so["count"]) == 24, "24 panels")
	_near(float(so["total_w"]), 2400.0, 1e-6, "2.4 kW")
	_ok(int(sm["series"]) == 6 and int(sm["parallel"]) == 4, "wired 6S × 4P")
	_near(float(sm["string_voc"]), 135.6, 0.01, "string Voc")
	_ok((sm["avg_normal"] as Vector3).dot(Vector3.UP) > 0.99, "a full ring of panels faces up on average")
	# Measured: a panel runs R 1.837 → 2.944, y 3.018 → 3.183.
	var pn: Dictionary = so["panels"][0]
	var rows: Array = pn["rows"]
	var r_lo := INF
	var r_hi := 0.0
	var y_hi := 0.0
	for row in rows:
		for p in row:
			var rr := Vector2((p as Vector3).x, (p as Vector3).z).length()
			r_lo = minf(r_lo, rr)
			r_hi = maxf(r_hi, rr)
			y_hi = maxf(y_hi, (p as Vector3).y)
	_near(r_lo, 1.837, 0.04, "panels start where the model's do")
	_near(r_hi, 2.944, 0.04, "panels end where the model's do")
	_near(y_hi, 3.183, 0.015, "panels crest where the model's do")
	_ok(not str(d["checks"]).contains("wider than the bay"), "the panels fit between the ribs")


func _test_bracing() -> void:
	var d := ToroidLabDesign.solve(ToroidLabPresets.braced_spec())
	var cables := 0
	var braces := 0
	for m in d["frame"]["members"]:
		if str(m["kind"]) == "cable":
			cables += 1
		elif str(m["kind"]) == "brace":
			braces += 1
	_ok(cables == 24, "X tension lines every other bay: 12 bays × 2 = 24")
	_ok(braces == 12, "zigzag tube braces every other bay: 12")
	var fits: Dictionary = d["bom"]["fittings"]
	_ok(int(fits.get("eye", 0)) == 48 and int(fits.get("swivel", 0)) == 24, "an eye per line end, a swivel per brace end")
	var rows := str(d["bom"]["rows"])
	_ok(rows.contains("Turnbuckle"), "a turnbuckle per line")
	# A tension line ends on its rings.
	var fr: Dictionary = d["frame"]
	var line: Dictionary = {}
	for m in fr["members"]:
		if str(m["kind"]) == "cable":
			line = m
			break
	var pa: Vector3 = (line["pts"] as PackedVector3Array)[0]
	_near(pa.y, float(fr["rings"][0]["y"]), 1e-4, "a line starts on the outer ground ring")
	var bad := ToroidLabSpec.resolve({"bracing": [{"from": 0, "to": 9}]})
	_ok(str(ToroidLabDesign.solve(bad)["checks"]).contains("not there"), "a brace to a missing ring is reported")


func _test_builder() -> void:
	var spec := ToroidLabPresets.braced_spec()
	var n := ToroidLabBuilder.build_node(spec, "T", {"record": true})
	var mi := n.get_node_or_null("Mesh") as MeshInstance3D
	_ok(mi != null and mi.mesh != null, "a Mesh child")
	_ok(mi.mesh.get_surface_count() >= 6, "a surface per material (%d)" % mi.mesh.get_surface_count())
	var bad := 0
	var tris := 0
	for si in mi.mesh.get_surface_count():
		var arr := mi.mesh.surface_get_arrays(si)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var nn: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		for i in range(0, v.size(), 3):
			tris += 1
			if (v[i + 1] - v[i]).cross(v[i + 2] - v[i]).dot(nn[i] + nn[i + 1] + nn[i + 2]) > 0.0:
				bad += 1
	_ok(bad == 0, "every triangle winds clockwise from its normal (%d of %d)" % [bad, tris])
	var aabb := mi.get_aabb()
	_near(aabb.size.x, 8.11, 0.06, "the built mesh is the measured width")
	_ok(aabb.position.y > -0.05, "nothing below the ground")
	# A ray straight down onto a panel picks it.
	var d := ToroidLabDesign.solve(spec)
	var c: Vector3 = d["solar"]["panels"][0]["centre"]
	var hit := ToroidLabBuilder.pick(n, c + Vector3(0, 5, 0), Vector3.DOWN)
	_ok(str(hit.get("kind", "")) == "panel", "a ray down onto a panel picks it (%s)" % str(hit))
	var rib0: Dictionary = d["frame"]["members"][0]
	var mid: Vector3 = (rib0["pts"] as PackedVector3Array)[8]
	var hit2 := ToroidLabBuilder.pick(n, mid + Vector3(3, 0.2, 0), (mid - (mid + Vector3(3, 0.2, 0))).normalized())
	_ok(str(hit2.get("kind", "")) in ["tube", "fitting", "canopy", "panel"], "a ray at a rib picks part of the frame")
	n.free()
	var n0 := ToroidLabBuilder.build_node(spec, "T0", {"assembly": 0.0})
	var m0 := n0.get_node("Mesh") as MeshInstance3D
	_ok(m0.mesh == null or m0.mesh.get_surface_count() <= 3, "assembly 0 shows at most the ground stage")
	n0.free()
	var ne := ToroidLabBuilder.build_node(spec, "TE", {"explode": 1.0})
	var me := ne.get_node("Mesh") as MeshInstance3D
	_ok(me.get_aabb().end.y > aabb.end.y + 0.3, "explode lifts the panels off")
	ne.free()
	var ps := ToroidLabDesign.packed_spec(d)
	_ok(float(ps["w_m"]) > 2.0 and float(ps["w_m"]) < 3.0 and float(ps["mass_kg"]) > 300.0, "packs to a bundle (%s)" % str(ps))


func _test_spec_and_files() -> void:
	var s := ToroidLabPresets.overview_spec()
	var js: Dictionary = JSON.parse_string(JSON.stringify(ToroidLabSpec.to_json_safe(s)))
	_ok(ToroidLabSpec.key_of(js) == ToroidLabSpec.key_of(s), "the spec survives JSON")
	_ok(ToroidLabDesign.solve(s) == ToroidLabDesign.solve(js), "a solved design is cached by its spec")
	var r := ToroidLabSpec.resolve({"torus": {"segments": 2}, "canopy": {"phi_in_deg": 10.0, "phi_out_deg": 30.0}})
	_ok(int(r["torus"]["segments"]) == ToroidLabSpec.MIN_SEGMENTS, "segments clamp")
	_ok(float(r["canopy"]["phi_in_deg"]) > float(r["canopy"]["phi_out_deg"]), "the canopy's inner edge stays inside its outer")
	_ok(ToroidLabSpec._int_list("17, 19") == [17, 19], "a typed skip list parses")
	var dir := OS.get_user_data_dir().path_join("toroidlab_selftest_files")
	var d := ToroidLabDesign.solve(s)
	var w := ToroidLabCam.write_all(d, dir)
	_ok(bool(w["ok"]), "the files write (%s)" % str(w["error"]))
	var files: Array = w["files"]
	var has_dxf := files.any(func(f): return str(f).ends_with(".dxf"))
	var has_bend := files.any(func(f): return str(f).contains("_bend_A1"))
	_ok(has_dxf and has_bend, "a sheet DXF and a bend template")
	var dxf_text := ""
	for f in files:
		if str(f).ends_with(".dxf"):
			dxf_text = FileAccess.get_file_as_string(str(f))
			break
	_ok(dxf_text.contains("OUTSIDE_CUT") and dxf_text.contains("FOLD") and dxf_text.contains("INSIDE_CUT"), "the DXF has cuts, holes and folds")
	var cs := ToroidLabBom.cut_sheet_text(d)
	_ok(cs.contains("CUT LIST") and cs.contains("CANOPY") and cs.contains("6S × 4P"), "the cut sheet has its sections")
	_ok(ToroidLabBom.tubes_csv(d).split("\n").size() >= 7, "the tube CSV lists every class")
	for f in files:
		DirAccess.remove_absolute(str(f))
	DirAccess.remove_absolute(dir)
	var sum := ToroidLabBuilder.panel_summary(s)
	_ok(int(sum["count"]) == 24 and float(sum["watts_per_panel"]) == 100.0, "the graph handoff summary")


func _test_builtins() -> void:
	for p in ToroidLabPresets.builtins():
		var d := ToroidLabDesign.solve(p["spec"])
		var errs: Array = (d["checks"] as Array).filter(func(c): return str(c["level"]) == "error")
		_ok(errs.is_empty(), "%s solves without an error %s" % [str(p["id"]), str(errs)])
	_ok(not ToroidLabPresets.builtin("overview_toroid").is_empty(), "the reference build is a built-in")
	var bare := ToroidLabDesign.solve(ToroidLabPresets.bare_spec())
	_ok((bare["canopy"]["pieces"] as Array).is_empty() and int(bare["solar"]["count"]) == 0, "a bare frame has no canopy or panels")
	_ok(int(bare["bom"]["fittings"].get("swivel", 0)) > 0, "a bare frame's braces are clamped on")
