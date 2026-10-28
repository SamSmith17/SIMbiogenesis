extends SceneTree

## Solar designer selftest (offline). The cells reproduce a real module's
## data sheet (JA Solar JAM60S20-380/MR from 120 half-cut M6 cells); the
## substring map (6 groups in 2 halves for half-cut, 3 for full cells); the
## single-diode fit passes through the maximum-power point and a uniformly lit
## module makes exactly its Wmp; bypass diodes (one shaded path costs about a
## substring — a third of a full-cell module, a sixth of a half-cut one); a
## partly shaded string shows two power peaks and the MPPT takes the higher;
## parallel strings; the tracker's rotation by hand and backtracking keeping
## the next row out of the shadow; the rack span check by hand; the layout,
## strings, lead reach and controller window; every built-in design without an
## error; the BOM, packed spec, graph preset and the JSON round trip.
##   Godot --headless --path . --script core/pvlab/pvlab_selftest.gd

const EXPECTED_CHECKS := 132

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
	_test_cells_and_module()
	_test_substrings()
	_test_iv_fit()
	_test_bypass()
	_test_peaks_and_parallel()
	_test_tracker()
	_test_rack()
	_test_layout_and_strings()
	_test_builtins()
	_test_json()
	_test_builder()
	_test_graph()
	_test_shading()
	_test_surface()
	_test_catalog()
	_test_type_patch()
	_test_frame_lip()
	_test_hardware()
	print("pvlab selftest: %d checks, %d failures" % [_checks, _fails])
	if _checks != EXPECTED_CHECKS:
		print("FAIL: ran %d checks, expected %d (a test function aborted?)" % [_checks, EXPECTED_CHECKS])
		_fails += 1
	print("PASS" if _fails == 0 else "FAILED")
	quit(0 if _fails == 0 else 1)


func _ja_derived() -> Dictionary:
	var m := PvLabPresets.module("ja_380").duplicate(true)
	m["electrical"]["mode"] = "derived"
	return PvLabModule.resolve(m)


func _test_cells_and_module() -> void:
	# M6 wafer: 166 mm square from a 223 mm ingot -> 8.3 mm chamfers, 274 cm².
	var ch := PvLabCells.chamfer_mm(166.0, 223.0)
	_near(ch, 8.32, 0.05, "M6 chamfer leg")
	_near(PvLabCells.wafer_area_cm2(166.0, ch), 274.2, 0.3, "M6 wafer area")
	var m := _ja_derived()
	var d := PvLabModule.derived_stc(m)
	# JA JAM60S20-380/MR data sheet: Voc 41.62, Isc 11.47, Vmp 34.77, Imp 10.93, 380 W.
	_near(float(d["voc"]), 41.62, 0.2, "derived Voc of 60 cells in series")
	_near(float(d["isc"]), 11.47, 0.15, "derived Isc of two half-cell paths")
	_near(float(d["wmp"]), 380.0, 6.0, "derived Wmp")
	_ok(PvLabModule.series_cells(m) == 60 and PvLabModule.parallel_paths(m) == 2, "half-cut: 60 in series, 2 paths")
	_ok(bool(PvLabModule.fit_report(m)["fits"]), "the JA cells fit inside its frame")
	var ds := PvLabModule.electrical(PvLabPresets.module("ja_380"))
	_near(float(ds["wmp"]), 380.0, 0.01, "datasheet mode keeps the nameplate")
	_near(float(ds["voc_coeff"]), -0.272, 1e-6, "datasheet Voc coefficient")
	# Fit-to-dims and back.
	var cf := PvLabModule.cells_to_fit(m)
	_ok(cf.x == 6 and cf.y >= 20, "cells to fit the JA face: 6 across, ≥ 20 rows (%s)" % str(cf))
	var poly := PvLabModule.derived_stc(PvLabPresets.module("poly_275"))
	_near(float(poly["voc"]), 38.4, 0.1, "poly 60-cell Voc")
	_near(float(poly["isc"]), 9.21, 0.1, "poly 60-cell Isc (square cast wafers)")


func _test_substrings() -> void:
	var m := _ja_derived()
	var subs := PvLabModule.substrings(m)
	_ok(subs.size() == 3, "three bypass diodes, three substrings")
	_ok((subs[0]["paths"] as Array).size() == 2, "half-cut: each substring is two halves in parallel")
	_ok(int(subs[0]["cells"]) == 20, "each half-substring path is 20 cells (2 columns × 10)")
	_ok(PvLabModule.sample_points(m).size() == 12, "12 shading samples (3 × 2 paths × 2)")
	var full := PvLabPresets.module("poly_275")
	var fs := PvLabModule.substrings(full)
	_ok(fs.size() == 3 and (fs[0]["paths"] as Array).size() == 1 and int(fs[0]["cells"]) == 20,
		"full cells: 3 substrings of 20 cells, one path each")
	var film := PvLabModule.substrings(PvLabPresets.module("cdte_420"))
	_ok(film.size() == 1 and not bool(film[0]["diode"]), "CdTe with no diodes: one substring, no diode")
	_ok(((film[0]["paths"] as Array)[0]["bands"] as Array).size() == 3, "a thin-film path averages in 3 bands")
	var jb := PvLabModule.jbox_points(m)
	_ok((jb["boxes"] as Array).size() == 3, "split junction boxes: three")


func _test_iv_fit() -> void:
	var model := PvLabIV.model_for(PvLabPresets.module("ja_380"))
	var cell: Dictionary = model["cell"]
	_ok(float(cell["rs"]) >= 0.0 and float(cell["a"]) > 0.02 and float(cell["a"]) < 0.05,
		"fitted cell: a %.4f V, Rs %.5f Ω" % [float(cell["a"]), float(cell["rs"])])
	var c := PvLabIV.module_curve(model, 1000.0, 25.0)
	_near(float(c["voc"]), 41.62, 0.05, "module curve: Voc at STC")
	var mpp := PvLabIV.array_mpp(model, [[_uniform(model, 1000.0)]], 25.0)
	_near(float(mpp["p"]), 380.0, 2.5, "uniform STC: the MPPT finds Wmp")
	_near(float(mpp["v"]), 34.77, 0.6, "uniform STC: at Vmp")
	var half := PvLabIV.array_mpp(model, [[_uniform(model, 500.0)]], 25.0)
	_near(float(half["p"]) / float(mpp["p"]), 0.5, 0.04, "half the light: about half the power")
	var hot := PvLabIV.array_mpp(model, [[_uniform(model, 1000.0)]], 60.0)
	_ok(float(hot["p"]) < float(mpp["p"]) * 0.9, "60 °C cells make less (%.0f W)" % float(hot["p"]))


func _uniform(model: Dictionary, g: float) -> Array:
	var out: Array = []
	for i in int(model["n_paths"]):
		out.append(g)
	return out


func _test_bypass() -> void:
	# Full-cell module: shade one substring's only path -> about a third off.
	var poly := PvLabIV.model_for(PvLabPresets.module("poly_275"))
	var p0 := float(PvLabIV.array_mpp(poly, [[[1000.0, 1000.0, 1000.0]]], 25.0)["p"])
	var p1 := float(PvLabIV.array_mpp(poly, [[[1000.0, 1000.0, 100.0]]], 25.0)["p"])
	_near(p1 / p0, 2.0 / 3.0, 0.05, "one shaded substring of three costs a third")
	# Half-cut: one shaded half still sends its substring's current through
	# the shared diode -> a third off, as a full-cell module...
	var ja := PvLabIV.model_for(PvLabPresets.module("ja_380"))
	var q0 := float(PvLabIV.array_mpp(ja, [[_uniform(ja, 1000.0)]], 25.0)["p"])
	var g := _uniform(ja, 1000.0)
	g[1] = 100.0
	var q1 := float(PvLabIV.array_mpp(ja, [[g]], 25.0)["p"])
	_ok(q1 / q0 > 0.6 and q1 / q0 < 0.72, "half-cut: one shaded half costs a substring (%.3f)" % (q1 / q0))
	# ...but a shadow along the bottom edge (every substring's lower half)
	# leaves the top halves working: about half, where a full-cell module with
	# a shaded cell in every substring is nearly dark.
	var row := _uniform(ja, 1000.0)
	for k in [1, 3, 5]:
		row[k] = 100.0
	var q2 := float(PvLabIV.array_mpp(ja, [[row]], 25.0)["p"])
	_ok(q2 / q0 > 0.45 and q2 / q0 < 0.62, "half-cut under a bottom-edge shadow keeps about half (%.3f)" % (q2 / q0))
	var p2 := float(PvLabIV.array_mpp(poly, [[[100.0, 100.0, 100.0]]], 25.0)["p"])
	_ok(p2 / p0 < 0.15, "full cells under the same shadow are nearly dark (%.3f)" % (p2 / p0))
	# No diode (CdTe): the module follows its weakest strip band.
	var cd := PvLabIV.model_for(PvLabPresets.module("cdte_420"))
	var r0 := float(PvLabIV.array_mpp(cd, [[[1000.0]]], 25.0)["p"])
	var r1 := float(PvLabIV.array_mpp(cd, [[[300.0]]], 25.0)["p"])
	_near(r1 / r0, 0.27, 0.05, "thin film with no diode follows its weakest strip")
	# Per-sample -> per-path: min over bands of each band's mean.
	var pts := PvLabModule.sample_points(PvLabPresets.module("poly_275"))
	var samples: Array = []
	for i in pts.size():
		samples.append(1000.0)
	samples[1] = 100.0
	var pg := PvLabIV.path_irradiance(PvLabPresets.module("poly_275"), samples)
	_ok(pg.size() == 3 and is_equal_approx(float(pg[0]), 100.0) and is_equal_approx(float(pg[1]), 1000.0),
		"a shaded sample limits its path: %s" % str(pg))


func _test_peaks_and_parallel() -> void:
	var poly := PvLabIV.model_for(PvLabPresets.module("poly_275"))
	var sun := [1000.0, 1000.0, 1000.0]
	var shade := [150.0, 150.0, 150.0]
	# Two of six modules fully shaded: the string's P–V curve has two peaks.
	var st := [sun, sun, sun, sun, shade, shade]
	var c := PvLabIV.string_curve(poly, st, 25.0)
	var ia: PackedFloat64Array = c["i"]
	var va: PackedFloat64Array = c["v"]
	var peaks := 0
	for k in range(1, ia.size() - 1):
		var p := ia[k] * va[k]
		if p > ia[k - 1] * va[k - 1] and p >= ia[k + 1] * va[k + 1]:
			peaks += 1
	_ok(peaks >= 2, "a partly shaded string has two power peaks (%d)" % peaks)
	var best := PvLabIV.array_mpp(poly, [st], 25.0)
	var all_sun := float(PvLabIV.array_mpp(poly, [[sun, sun, sun, sun, sun, sun]], 25.0)["p"])
	# The global peak: four lit modules at full current, the two shaded ones bypassed.
	_ok(float(best["p"]) > all_sun * 0.62 and float(best["p"]) < all_sun * 0.7,
		"the MPPT takes the higher peak (%.0f of %.0f W)" % [float(best["p"]), all_sun])
	# Parallel strings: two equal strings make twice one.
	var one := float(PvLabIV.array_mpp(poly, [[sun, sun, sun]], 25.0)["p"])
	var two := float(PvLabIV.array_mpp(poly, [[sun, sun, sun], [sun, sun, sun]], 25.0)["p"])
	_near(two / one, 2.0, 0.02, "two equal strings in parallel: twice the power")
	# A shaded module in one of two parallel strings: the strings share one
	# voltage, so the array makes less than each string at its own MPP.
	var mixed := PvLabIV.array_mpp(poly, [[sun, sun, sun], [sun, sun, shade]], 25.0)
	_ok(float(mixed["p"]) > one * 1.2 and float(mixed["p"]) < one * (1.0 + 2.0 / 3.0),
		"parallel strings with one shaded module: mismatch loss (%.0f W)" % float(mixed["p"]))
	_ok((mixed["strings"] as Array).size() == 2, "per-string operating points reported")


func _test_tracker() -> void:
	# By hand (Marion & Dobos eq. 7, horizontal N–S axis): sun due east at 30°
	# -> −60° (toward the east); due west at 45° -> +45°; due south -> 0.
	_near(PvLabTracker.ideal_angle(90.0, 30.0, 180.0, 0.0), -60.0, 1e-3, "sun east at 30°: −60°")
	_near(PvLabTracker.ideal_angle(270.0, 45.0, 180.0, 0.0), 45.0, 1e-3, "sun west at 45°: +45°")
	_near(PvLabTracker.ideal_angle(180.0, 50.0, 180.0, 0.0), 0.0, 1e-3, "sun on the axis's plane: flat")
	# Backtracking by hand: R = −80°, GCR 0.35 -> −80 + acos(cos 80°/0.35) = −19.74°.
	_near(PvLabTracker.backtrack(-80.0, 0.35), -19.74, 0.05, "backtracking at −80°, GCR 0.35")
	_near(PvLabTracker.backtrack(-40.0, 0.35), -40.0, 1e-6, "no backtracking when no shade")
	# Backtracked rows never shade the next one: L cos(R − θ) ≤ p cos θ.
	var gcr := 0.4
	var ok := true
	for th in [-85.0, -75.0, -65.0, -50.0, 50.0, 70.0, 84.0]:
		var r := PvLabTracker.backtrack(th, gcr)
		var shadow := cos(deg_to_rad(r - th))
		if shadow > cos(deg_to_rad(th)) / gcr + 1e-6:
			ok = false
	_ok(ok, "backtracked rows stay out of each other's shadow")
	var n0 := PvLabTracker.normal_at(0.0, 180.0, 0.0)
	_ok(n0.is_equal_approx(Vector3.UP), "at rotation 0 a horizontal tracker faces up")
	var nw := PvLabTracker.normal_at(30.0, 180.0, 0.0)
	_ok(nw.x < -0.4 and nw.y > 0.8, "a positive rotation faces west (−X)")
	var o := PvLabTracker.orientation_of(nw)
	_near(float(o["tilt_deg"]), 30.0, 1e-3, "orientation: tilt")
	_near(float(o["azimuth_deg"]), 270.0, 1e-3, "orientation: azimuth west")
	_near(PvLabTracker.angle_at(90.0, -5.0, 180.0, {}), 0.0, 1e-6, "night: stowed flat")
	_near(PvLabTracker.angle_at(90.0, 30.0, 180.0, {}, 0.0, 25.0), 0.0, 1e-6, "high wind: stowed")
	_near(PvLabTracker.angle_at(90.0, 5.0, 180.0, {"max_deg": 55.0}), -55.0, 1e-6, "clamped at the limit")


func _test_rack() -> void:
	# P1000 under 1000 N/m by hand: bending √(8·3.31e-6·172e6/1000) = 2.134 m;
	# deflection (384·203e9·7.7e-8/(5·1000·180))^(1/3) = 1.882 m.
	var sp := PvLabRack.allowed_span_m("p1000", 1000.0)
	_near(float(sp["bending"]), 2.134, 0.005, "P1000 bending span")
	_near(float(sp["deflection"]), 1.882, 0.005, "P1000 deflection span (L/180)")
	_near(float(sp["allowed"]), 1.882, 0.005, "deflection governs")
	var xs := PvLabRack.support_xs(6.0, 1.8)
	_ok(xs.size() >= 4 and float(xs[1]) - float(xs[0]) <= 1.8 + 1e-6, "supports no more than the spacing apart")


func _test_layout_and_strings() -> void:
	var d := PvLabDesign.solve(PvLabPresets.builtin("backyard_2x4")["spec"])
	var lay: Dictionary = d["layout"]
	_ok((lay["panels"] as Array).size() == 12, "backyard: 12 modules")
	_ok((d["strings"] as Array).size() == 2 and ((d["strings"] as Array)[0] as Array).size() == 6, "two strings of six")
	_ok(int(d["wiring"]["jumpers"]) == 0, "1.2 m leads reach every series link (%d jumpers)" % int(d["wiring"]["jumpers"]))
	# The modules face +Z (south) tilted 30°: their normal's z is positive.
	var xf: Transform3D = (lay["panels"] as Array)[0]["xf"]
	var n := xf.basis * Vector3.UP
	_near(rad_to_deg(acos(n.y)), 30.0, 0.01, "module tilt 30°")
	_ok(n.z > 0.0, "modules face +Z (south at yaw 0)")
	var low_y := xf.origin.y
	_ok(low_y > 0.5, "modules above the clearance")
	_ok(not (d["members"] as Array).is_empty(), "the rack has members")
	# Auto string size against a 150 V input: JA cold Voc 41.62·1.095 -> 3 in series.
	var e := PvLabModule.electrical(PvLabPresets.module("ja_380"))
	_ok(PvLabArray.auto_string_size(PvLabPresets.module("ja_380"), 12, {"max_voc": 150.0}) == 3,
		"auto string size for 150 V: 3")
	var w := PvLabArray.window(e, 4, PvLabArray.resolve_target({"max_voc": 150.0}))
	_ok(not bool(w["ok"]) and float(w["voc_cold"]) > 150.0, "4 × JA exceeds 150 V on a cold morning")
	# Tracker layout.
	var t := PvLabDesign.solve(PvLabPresets.builtin("tracker_1p")["spec"])
	_ok((t["layout"]["panels"] as Array).size() == 36 and (t["layout"]["heads"] as Array).size() == 3, "tracker: 36 modules on 3 rows")
	_near(float(t["layout"]["gcr"]), 0.35, 0.01, "tracker GCR")
	var px := PvLabArray.panel_xf(t["layout"], (t["layout"]["panels"] as Array)[0], 30.0)
	_ok((px.basis * Vector3.UP).x < -0.4, "a tracker module turned +30° faces −X")
	# Strings back from graph links.
	var ids := ["a", "b", "c", "d"]
	var chains := PvLabArray.strings_from_links(ids, {"a": "b", "c": "d"})
	_ok(chains.size() == 2 and (chains[0] as Array) == [0, 1] and (chains[1] as Array) == [2, 3],
		"strings from graph links: %s" % str(chains))
	var g := PvLabDesign.graph_preset(PvLabDesign.solve(PvLabPresets.builtin("unistrut_ground")["spec"]))
	_ok((g["groups"] as Array).size() == 2 and int((g["groups"] as Array)[0]["series"]) == 8, "two MPPT inputs of 8-module strings")


func _test_builtins() -> void:
	var errors: Array = []
	for b in PvLabPresets.builtins():
		var d := PvLabDesign.solve(b["spec"])
		for c in d["checks"]:
			if str(c["level"]) == "error":
				errors.append("%s: %s" % [str(b["id"]), str(c["text"])])
	_ok(errors.is_empty(), "every built-in design solves without an error: %s" % str(errors))
	var fit_errors: Array = []
	for m in PvLabPresets.modules():
		if not bool(PvLabModule.fit_report(m["spec"])["fits"]):
			fit_errors.append(str(m["id"]))
	_ok(fit_errors.is_empty(), "every built-in module's cells fit its face: %s" % str(fit_errors))
	var d2 := PvLabDesign.solve(PvLabPresets.builtin("unistrut_ground")["spec"])
	_ok(float(d2["bom"]["mass_kg"]) > 16.0 * 20.0, "BOM mass includes the modules")
	_ok(float(d2["bom"]["cost_usd"]) > 0.0 and (d2["bom"]["rows"] as Array).size() >= 4, "BOM rows and cost")
	var ps := PvLabDesign.packed_spec(d2)
	_ok(float(ps["w_m"]) > 1.0 and float(ps["h_m"]) > 0.3, "packed spec envelope")


func _test_json() -> void:
	var s: Dictionary = PvLabPresets.builtin("tracker_1p")["spec"]
	var js := JSON.stringify(PvLabSpec.to_json_safe(s))
	var back: Variant = JSON.parse_string(js)
	_ok(back is Dictionary, "JSON parses")
	_ok(PvLabSpec.key_of(back) == PvLabSpec.key_of(s), "JSON round trip keeps the design key")
	var m2: Dictionary = PvLabModule.resolve((back as Dictionary)["module"])
	_ok(is_equal_approx(float(PvLabModule.electrical(m2)["wmp"]), 380.0), "module survives JSON")


func _test_builder() -> void:
	var d := PvLabDesign.solve(PvLabPresets.builtin("backyard_2x4")["spec"])
	var root := PvLabBuilder.build_from_design(d)
	var panels := root.get_node_or_null("Panels") as MultiMeshInstance3D
	_ok(panels != null and panels.multimesh.instance_count == 12, "12 modules in the Panels MultiMesh")
	_ok(root.get_node_or_null("Rack") != null and root.get_node_or_null("CollisionMesh") != null, "rack and collision nodes")
	# Every module triangle is wound clockwise from outside (cross · n < 0).
	var bad := 0
	var mesh := PvLabBuilder.module_mesh(d["module"])
	for si in mesh.get_surface_count():
		var arr := mesh.surface_get_arrays(si)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var n: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		for k in range(0, v.size(), 3):
			if (v[k + 1] - v[k]).cross(v[k + 2] - v[k]).dot(n[k]) > 0.0:
				bad += 1
	_ok(bad == 0, "module mesh winding (%d bad)" % bad)
	_ok(mesh.get_surface_count() >= 4, "module surfaces: face, frame, back, boxes")
	var rack := root.get_node("Rack") as MeshInstance3D
	var rbad := 0
	for si in rack.mesh.get_surface_count():
		var arr2 := rack.mesh.surface_get_arrays(si)
		var v2: PackedVector3Array = arr2[Mesh.ARRAY_VERTEX]
		var n2: PackedVector3Array = arr2[Mesh.ARRAY_NORMAL]
		for k in range(0, v2.size(), 3):
			if (v2[k + 1] - v2[k]).cross(v2[k + 2] - v2[k]).dot(n2[k]) > 0.0:
				rbad += 1
	_ok(rbad == 0, "rack winding (%d bad)" % rbad)
	# Picking from above lands on a module.
	var hit := PvLabBuilder.pick_panel(d, Vector3(0.6, 10.0, 0.0), Vector3.DOWN)
	_ok(not hit.is_empty(), "a ray from above picks a module")
	root.free()
	var t := PvLabDesign.solve(PvLabPresets.builtin("tracker_1p")["spec"])
	var tr := PvLabBuilder.build_from_design(t)
	PvLabBuilder.set_tracker_angle(tr, 30.0)
	var head := tr.get_node("TrackerHead0") as Node3D
	_ok(head != null and (head.basis * Vector3.UP).x < -0.4, "tracker heads turn")
	tr.free()
	var errs := 0
	for b in PvLabPresets.builtins():
		var node := PvLabBuilder.build_node(b["spec"], "X", {"pieces": true})
		var tagged := 0
		var stack: Array = [node]
		while not stack.is_empty():
			var nn: Node = stack.pop_back()
			if nn.has_meta("structure_piece"):
				tagged += 1
			for c in nn.get_children():
				stack.append(c)
		if tagged < 4:
			errs += 1
		node.free()
	_ok(errs == 0, "every built-in builds in pieces for the crews")


class FakeView extends Node:
	var model: GraphModel = null
	var _history_suppress := false
	var _active_scope_id := "root"


func _test_graph() -> void:
	var view := FakeView.new()
	view.model = GraphModel.new()
	var m := view.model
	# A controller on the canvas: new arrays wire to it.
	var ctrl := m.generate_item_id()
	m.add_item({"id": ctrl, "type": "controller", "x": 300.0, "y": 0.0, "width": 160.0, "height": 120.0,
		"scope_id": "root", "specs": {"name": "EG4", "max_voc": 480.0}, "is_virtual": false})
	var spec: Dictionary = PvLabPresets.builtin("unistrut_ground")["spec"]
	var d := PvLabDesign.solve(spec)
	var ids := GraphPvLabArrays.upsert(view, d, "pvlab_t1", {"name": "Test", "prop_id": "p1", "tilt_deg": 35.0,
		"azimuth_deg": 180.0})
	_ok(ids.size() == 2, "one compound per MPPT input (%d)" % ids.size())
	var c0 := m.get_item(str(ids[0]))
	var kids: Array = m.get_items_in_scope(str(c0["child_scope_id"]))
	_ok(kids.size() == 8, "the first input holds its 8 panels (%d)" % kids.size())
	var eps: Array = (c0["specs"] as Dictionary).get("exposed_ports", [])
	_ok(eps.size() == 2, "one + / − pair at the level it sits in")
	var flat := GraphNesting.flat_connections(m)
	var vocs := PvElectrical.branch_vocs_for_controller_flat(m, ctrl, flat, 25.0)
	var e := PvLabModule.electrical(d["module"])
	var want := float(e["voc"]) * 8.0
	var found := false
	for v in vocs:
		if absf(float(v) - want) < 0.5:
			found = true
	_ok(found, "the controller sees each 8-module string's Voc (%s vs %.1f)" % [str(vocs), want])
	var gs := GraphPvLabArrays.strings_from_model(m, "pvlab_t1")
	_ok(gs.size() == 2 and str(gs[0][0]) == str(d["strings"][0]), "strings read back from the graph: %s" % str(gs))
	# Re-seed in place: same compounds, the wire to the controller survives.
	var wires_before := 0
	for cn in m.connections:
		if str((cn as Dictionary).get("target_item_id", "")) == ctrl:
			wires_before += 1
	var ids2 := GraphPvLabArrays.upsert(view, d, "pvlab_t1", {"name": "Test", "prop_id": "p1"})
	var wires_after := 0
	for cn in m.connections:
		if str((cn as Dictionary).get("target_item_id", "")) == ctrl:
			wires_after += 1
	_ok(str(ids2) == str(ids) and wires_after == wires_before and wires_before == 4,
		"re-seeding rebuilds the insides in place (wires %d -> %d)" % [wires_before, wires_after])
	# One input now: the second compound goes.
	var s1 := spec.duplicate(true)
	s1["strings"]["inputs"] = 1
	GraphPvLabArrays.upsert(view, PvLabDesign.solve(s1), "pvlab_t1", {})
	_ok(GraphPvLabArrays.find(m, "pvlab_t1").size() == 1, "fewer inputs drop the extra compound")
	GraphPvLabArrays.remove(view, "pvlab_t1")
	_ok(GraphPvLabArrays.find(m, "pvlab_t1").is_empty() and m.items.size() == 1, "remove takes the array and its panels")
	view.free()


func _test_shading() -> void:
	# POA on a plane facing the sun at normal incidence, clear sky: beam ≈ DNI.
	var p := PvLabShading.poa(180.0, 40.0, 50.0, 180.0, 0.0, false, 0.0)
	var dni := SolarIrradiance.dni_clear_sky_wm2(40.0)
	_near(float(p["beam"]), dni, 1.0, "facing the sun: the beam is the clear-sky DNI")
	_ok(float(p["diffuse_share"]) > 0.05 and float(p["diffuse_share"]) < 0.3, "clear sky: diffuse a small share (%.2f)" % float(p["diffuse_share"]))
	var back := PvLabShading.poa(0.0, 40.0, 50.0, 180.0, 0.0, false, 0.0)
	_ok(float(back["beam"]) == 0.0, "sun behind the plane: no beam")
	# One shaded sample costs its substring.
	var d := PvLabDesign.solve(PvLabPresets.builtin("backyard_2x4")["spec"])
	var per := PvLabModule.sample_points(d["module"]).size()
	var n := (d["layout"]["panels"] as Array).size()
	var lit := PackedByteArray()
	lit.resize(per * n)
	lit.fill(1)
	_near(PvLabShading.factor_from_lit(d, lit, 0.2), 1.0, 1e-6, "all lit: factor 1")
	lit[0] = 0
	var f1 := PvLabShading.factor_from_lit(d, lit, 0.2)
	# A 6-module string with one substring of one module bypassed: ~1/18 of that
	# string, ~1/36 of the array.
	_ok(f1 < 0.99 and f1 > 0.94, "one shaded sample costs about one substring (%.3f)" % f1)
	var world := PvLabShading.world_samples(d, Transform3D.IDENTITY)
	_ok((world["pos"] as PackedVector3Array).size() == per * n, "a world sample per module sample")


func _test_surface() -> void:
	# A 12 × 8 m house with a gabled roof: a point on a slope has the roof's pitch.
	var poly := PackedVector2Array([Vector2(-6, -4), Vector2(6, -4), Vector2(6, 4), Vector2(-6, 4)])
	var roof := {"shape": "gabled", "angle_deg": 30.0, "orientation": "along", "roof_height_m": 0.0}
	var rp := BuildingBuilder.roof_plane_at(poly, roof, 7.0, 10.0, Vector2(0.0, 2.0))
	_ok(not rp.is_empty() and not bool(rp["flat"]), "a gabled roof is pitched")
	var tilt := rad_to_deg(acos(clampf((rp["normal"] as Vector3).y, -1.0, 1.0)))
	_ok(tilt > 15.0 and tilt < 45.0, "the slope's normal has the roof's pitch (%.1f°)" % tilt)
	_ok(float(rp["y"]) > 10.0 and float(rp["y"]) < 17.0, "the roof point is between eave and ridge (%.2f)" % float(rp["y"]))
	var flat := BuildingBuilder.roof_plane_at(poly, {"shape": "flat"}, 5.0, 10.0, Vector2(1.0, 1.0))
	_ok(bool(flat["flat"]) and is_equal_approx(float(flat["y"]), 15.0), "a flat roof is the top")
	# Lying in a slope: +Y the normal, +Z down the slope, right-handed.
	var n := Vector3(0.0, cos(deg_to_rad(30.0)), sin(deg_to_rad(30.0)))
	var b := PvSurfaceAim.surface_basis(n)
	_ok(b.y.is_equal_approx(n.normalized()) and b.z.y < 0.0 and absf(b.determinant() - 1.0) < 1e-4,
		"surface basis: normal up, +Z downhill, right-handed")
	var t := Transform3D(b, Vector3(3, 4, 5))
	_ok(PlacedPropService._xf_from_array(PlacedPropService._xf_to_array(t)).is_equal_approx(t), "host link round trip")


## The catalog of real modules: every entry self-consistent and buildable.
func _test_catalog() -> void:
	var all := PvLabCatalog.all()
	_ok(all.size() >= 20, "the catalog lists %d real modules" % all.size())
	var bad: Array = []
	var unfit: Array = []
	for e in all:
		var w := float(e["wmp"])
		var vi := float(e["vmp"]) * float(e["imp"])
		var eff := w / (float(e["w"]) * float(e["h"])) * 1.0e5
		if absf(vi - w) / w > 0.02 or float(e["voc"]) <= float(e["vmp"]) or float(e["isc"]) <= float(e["imp"]) \
				or eff < 12.0 or eff > 24.5:
			bad.append(str(e["id"]))
		var m := PvLabCatalog.module_spec(e)
		if not bool(PvLabModule.fit_report(m)["fits"]):
			unfit.append(str(e["id"]))
	_ok(bad.is_empty(), "every catalog entry: Vmp×Imp ≈ Pmax, Voc > Vmp, Isc > Imp, 12–24.5 %% efficient (%s)" % str(bad))
	_ok(unfit.is_empty(), "every catalog module's cells fit its face (%s)" % str(unfit))
	var ja := PvLabCatalog.module_spec(PvLabCatalog.by_id("ja_jam54s30_410"))
	var e2 := PvLabModule.electrical(ja)
	_near(float(e2["wmp"]), 410.0, 0.01, "JA 410: the nameplate drives the electrics")
	_ok(str(ja["cells"]["format"]) == "m10", "JA 410 is laid out in M10 (182 mm) cells (%s)" % str(ja["cells"]["format"]))
	_near(float(PvLabModule.derived_stc(ja)["wmp"]), 410.0, 410.0 * 0.12, "JA 410's cells as drawn make about its nameplate")
	_ok(PvLabCatalog.search("jinko tiger neo").size() == 1, "search: 'jinko tiger neo' finds one")
	_ok(PvLabCatalog.search("660 bifacial").size() == 2, "search: '660 bifacial' finds the two 660 W bifacials")
	_ok(PvLabCatalog.search("").size() == all.size(), "an empty search lists everything")
	var bi := PvLabCatalog.module_spec(PvLabCatalog.by_id("cs_cs7n_660mb_ag"))
	_ok(str(bi["type"]) == "glass_glass" and str(bi["backsheet"]["back"]) == "clear",
		"a bifacial catalog module is glass–glass with a clear rear")


## Switching the type changes the build, not just a label.
func _test_type_patch() -> void:
	var base := PvLabPresets.module("ja_380")
	var flex := PvLabModule.type_patch(base, "flexible")
	_ok(str(flex["frame"]["style"]) == "none" and float(flex["dims_mm"]["t"]) < 4.0 and str(flex["glass"]) == "etfe",
		"flexible: frameless, thin, ETFE")
	_ok(PvLabModule.corner_radius_mm(flex) > 5.0, "flexible: rounded corners")
	var tf := PvLabModule.type_patch(base, "thin_film")
	_ok(str(tf["cells"]["tech"]) == "cdte" and str(tf["cells"]["cut"]) == "strip", "thin film: CdTe strips")
	var gg := PvLabModule.type_patch(base, "glass_glass")
	_ok(str(gg["backsheet"]["back"]) == "clear", "glass–glass: clear rear")
	var fo := PvLabModule.type_patch(base, "folding")
	_ok(str(fo["frame"]["style"]) == "fabric", "folding: fabric case")
	var back := PvLabModule.type_patch(tf, "rigid")
	_ok(str(back["cells"]["tech"]) == "mono_perc" and str(back["frame"]["style"]) == "silver",
		"thin film back to rigid: wafer cells in a frame")
	# Each build gives a different mesh.
	var counts := {}
	for t in PvLabModule.TYPES:
		var mm := PvLabBuilder.module_mesh(PvLabModule.type_patch(base, t))
		var nv := 0
		for si in mm.get_surface_count():
			nv += mm.surface_get_array_len(si)
		counts[t] = "%d|%s" % [nv, str(mm.get_aabb().size.snappedf(0.0001))]
	var distinct := {}
	for k in counts:
		distinct[counts[k]] = true
	_ok(distinct.size() == PvLabModule.TYPES.size(), "every type builds its own mesh (%s)" % str(counts))


## The frame's lip stands proud of the glass and reaches over its edge.
func _test_frame_lip() -> void:
	var m := PvLabPresets.module("ja_380")
	var mesh := PvLabBuilder.module_mesh(m)
	var face: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var frame: PackedVector3Array = mesh.surface_get_arrays(1)[Mesh.ARRAY_VERTEX]
	var glass_y := face[0].y
	var glass_half := 0.0
	for v in face:
		glass_half = maxf(glass_half, absf(v.x))
	var top := -INF
	for v in frame:
		top = maxf(top, v.y)
	_near((top - glass_y) * 1000.0, float(m["frame"]["lip_mm"]), 0.01, "the lip stands %.1f mm proud of the glass" % float(m["frame"]["lip_mm"]))
	var w := float(m["dims_mm"]["w"]) * 0.001
	var lip_in := w * 0.5 - float(m["frame"]["width_mm"]) * 0.001
	_near((glass_half - lip_in) * 1000.0, float(m["frame"]["overlap_mm"]), 0.01, "the glass runs under the lip")


## The rack is drawn down to the part, and the BOM counts what is drawn.
func _test_hardware() -> void:
	var d := PvLabDesign.solve(PvLabPresets.builtin("roof_flush_rail")["spec"])
	var pc := PvLabHardware.counts(d["parts"])
	# 2 module rows × 2 rails each = 4 rails; 5 modules across.
	_ok(int(pc.get("end_clamp", 0)) == 8, "roof: 2 end clamps per rail (%d)" % int(pc.get("end_clamp", 0)))
	_ok(int(pc.get("mid_clamp", 0)) == 16, "roof: a mid clamp per gap per rail (%d)" % int(pc.get("mid_clamp", 0)))
	_ok(int(pc.get("l_foot", 0)) > 0 and int(pc.get("end_cap", 0)) == 8 and int(pc.get("ground_lug", 0)) == 4,
		"roof: L-feet, end caps, a grounding lug per rail")
	var bom_q := {}
	for r in d["bom"]["rows"]:
		if r.has("part"):
			bom_q[str(r["part"])] = int(r["qty"])
	_ok(str(bom_q) == str(pc), "the BOM lists exactly the parts drawn")
	var fc := PvLabHardware.fastener_counts(d["parts"])
	_ok(int(fc.get("tbolt_m8", 0)) == int(pc["end_clamp"]) + int(pc["mid_clamp"]) + int(pc["l_foot"]) + int(pc["ground_lug"]),
		"each clamp, L-foot and lug brings its T-bolt")
	var lum := PvLabDesign.solve(PvLabPresets.builtin("backyard_2x4")["spec"])
	var lc := PvLabHardware.counts(lum["parts"])
	_ok(int(lc.get("hurricane_tie", 0)) > 0 and int(lc.get("post_cap", 0)) > 0 and int(lc.get("ground_screw", 0)) > 0,
		"a 2x4 rack: hurricane ties, post caps, ground screws")
	var trk := PvLabDesign.solve(PvLabPresets.builtin("tracker_1p")["spec"])
	var tc := PvLabHardware.counts(trk["parts"])
	_ok(int(tc.get("slew_drive", 0)) == 3 and int(tc.get("module_bolts", 0)) == 36 and int(tc.get("tube_clamp", 0)) == 72,
		"tracker: a slew drive a row, bolts per module, two rail clamps per module (%s)" % str(tc))
	# Every part draws, and a ray straight down onto a mid clamp picks it.
	var accs := {}
	for p in d["parts"]:
		PvLabBuilder.emit_part(accs, p)
	_ok(accs.size() >= 4, "parts draw in %d finishes" % accs.size())
	var mid := {}
	var mi := -1
	for i in (d["parts"] as Array).size():
		if str(d["parts"][i]["type"]) == "mid_clamp":
			mid = d["parts"][i]
			mi = i
			break
	var top: Vector3 = (mid["xf"] as Transform3D) * Vector3(0, 0.05, 0)
	var hit := PvLabBuilder.pick_any(d, top + Vector3(0, 1, 0), Vector3.DOWN, 0.0, false)
	_ok(str(hit.get("kind", "")) == "part" and int(hit.get("index", -1)) == mi, "picking a mid clamp from above (%s)" % str(hit))
