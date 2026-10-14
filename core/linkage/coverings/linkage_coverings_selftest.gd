extends SceneTree
## Coverings / floor deck / shade tarps / cut plan (A4) == the JS dump
## (core/linkage/testdata/parity/*.json "a4", tools/linkage_parity_dump.mjs).
##
##   Godot --headless --path . --script core/linkage/coverings/linkage_coverings_selftest.gd
##
## Geometry is compared relative to an anchor both sides share: JS recentres
## the ring (shiftGeometryXZ), the game does not. Carries EXPECTED_CHECKS —
## a Godot runtime error aborts a test function while PASS still prints.

const EXPECTED_CHECKS := 75
const PRESETS := ["constellation", "starshade_2x3_folding_panels", "starshade_hex",
	"starshade_v1_soak_2026", "stellarator"]
const TOL := 2e-3

var _checks := 0
var _fails := 0


func _initialize() -> void:
	_test_nesting_unit()
	_test_fabric_unit()
	for name in PRESETS:
		_test_preset(name)
	_test_bom_enclosure()
	if _checks != EXPECTED_CHECKS:
		print("  FAIL: ran %d checks, expected %d (a test function aborted?)" % [_checks, EXPECTED_CHECKS])
		_fails += 1
	if _fails == 0:
		print("LINKAGE COVERINGS SELFTEST: PASS (%d checks)" % _checks)
	else:
		print("LINKAGE COVERINGS SELFTEST: FAIL (%d/%d)" % [_fails, _checks])
	quit(0 if _fails == 0 else 1)


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
		print("  FAIL: " + label)


func _read_json(path: String):
	var f := FileAccess.open(path, FileAccess.READ)
	return JSON.parse_string(f.get_as_text()) if f != null else null


static func _v3(o) -> Vector3:
	if o is Array:
		return Vector3(float(o[0]), float(o[1]), float(o[2]))
	return Vector3(float(o["x"]), float(o["y"]), float(o["z"]))


## A 4 × 8 sheet: an exact 48 × 96 rectangle is one full sheet; a 100 in
## wide trapezoid needs more than one and reports seams + marks.
func _test_nesting_unit() -> void:
	var rect := [Vector2(0, 0), Vector2(96, 0), Vector2(96, 48), Vector2(0, 48)]
	var n := LinkageSheetNesting.nest(rect, {"widthIn": 48.0, "lengthIn": 96.0})
	_check(int(n["sheet_count"]) == 1 and bool(n["pieces"][0]["is_full_sheet"]), "nest: a sheet-sized rectangle is one full sheet")
	var trap := [Vector2(0, 0), Vector2(100, 0), Vector2(80, 40), Vector2(20, 40)]
	var t := LinkageSheetNesting.nest(trap, {"widthIn": 48.0, "lengthIn": 96.0})
	_check(int(t["sheet_count"]) >= 2 and float(t["seam_count"]) >= 1.0, "nest: a wide trapezoid takes %d sheets, %s seams" % [int(t["sheet_count"]), str(t["seam_count"])])
	var clip := LinkageSheetNesting.clip_polygon_to_rect(trap, 0, 0, 50, 40)
	_check(absf(LinkageSheetNesting.polygon_area(clip) - 1600.0) < 1e-3, "clip: left half of the trapezoid (%.1f)" % LinkageSheetNesting.polygon_area(clip))
	_check(LinkageCoveringPlan.fmt_in(22.1875) == "22 3/16\"" and LinkageCoveringPlan.fmt_in(0.5) == "1/2\"", "inch fractions")


func _test_fabric_unit() -> void:
	var band := [Vector2(0, 0), Vector2(150, 0), Vector2(130, 40), Vector2(20, 40)]
	var pat := LinkageFabricPattern.build(band, {"rollWidthIn": 60.0, "hemIn": 1.0, "seamIn": 0.5, "stretchPct": 2.0, "grommetSpacingIn": 12.0})
	_check(int(pat["panel_count"]) == 3 and int(pat["seam_count"]) == 2, "fabric: a 147 in band on a 60 in roll is 3 panels")
	var all_fit := true
	for pn in pat["panels"]:
		all_fit = all_fit and bool(pn["fits_roll"])
	_check(all_fit and int(pat["grommet_count"]) > 0, "fabric: every panel fits the roll, grommets placed")


func _test_preset(name: String) -> void:
	var fx = _read_json("res://core/linkage/testdata/parity/%s.json" % name)
	var pr = _read_json("res://core/linkage/presets/ll_%s.json" % name)
	if not (fx is Dictionary) or not (pr is Dictionary):
		_check(false, "%s fixtures readable" % name)
		return
	var p := LinkageParams.new()
	p.from_config(pr)
	var fold := deg_to_rad(float(fx["deployedDeg"]))
	var frame := LinkageSolver.solve(p, fold)
	var beams: Array = (frame["beams"] as Array).duplicate()
	beams.append_array(LinkageGeometry.support_beams(frame, p, fold))
	var floor := LinkageFloor.floor_beams(frame["beams"], p, fold)
	beams.append_array(floor)
	var a4: Dictionary = fx["a4"]
	# The shared anchor: the base copy's first beam (non-radial), else the
	# first floor beam (the deck / floor beams are the base copy in both).
	var g_anchor: Vector3 = frame["beams"][0]["p1"]
	var j_anchor := _v3(fx["anchor"])
	var radial := not LinkageRadialArray.deployed_plan(p).is_empty()
	if radial:
		var jf = a4.get("floor")
		_check(jf is Dictionary and not floor.is_empty(), "%s radial: floor beams give the anchor" % name)
		if not (jf is Dictionary) or floor.is_empty():
			return
		g_anchor = floor[0]["p1"]
		j_anchor = _v3(jf["beams"][0]["p1"])
	var deck := LinkageFloor.deck(beams, p)
	var floor_top := float(deck["y_top"]) if not deck.is_empty() else NAN
	# --- coverings ---
	var cov := LinkageCoverings.compute(beams, p, floor_top)
	var jc = a4.get("coverings")
	var cov_on := bool(LinkageCoverings.config(p)["enabled"])
	_check((jc is Dictionary) == cov_on, "%s coverings enabled as in JS" % name)
	if cov_on and jc is Dictionary:
		var js_shapes: Array = jc["baseShapes"]
		var gs: Array = cov["shapes"]
		_check(gs.size() == js_shapes.size(), "%s covering shapes %d == JS %d" % [name, gs.size(), js_shapes.size()])
		var worst := 0.0
		var keys_ok := true
		var dims_ok := true
		var bad := ""
		for i in mini(gs.size(), js_shapes.size()):
			var g: Dictionary = gs[i]
			var j: Dictionary = js_shapes[i]
			if LinkagePartKeys.part_key(g, "wall") != str(j["key"]) or str(g["kind"]) != str(j["kind"]):
				keys_ok = false
				bad = "%s vs %s" % [LinkagePartKeys.part_key(g, "wall"), str(j["key"])]
			for k in (g["corners"] as Array).size():
				worst = maxf(worst, ((g["corners"][k] as Vector3) - g_anchor).distance_to(_v3(j["corners3D"][k]) - j_anchor))
			for f in [["area_in2", "areaIn2", 0.11], ["width_bottom_in", "widthBottomIn", TOL], ["width_top_in", "widthTopIn", TOL],
					["slant_height_in", "slantHeightIn", TOL], ["mount_offset_in", "mountOffsetIn", TOL]]:
				if absf(float(g[f[0]]) - float(j[f[1]])) > float(f[2]):
					dims_ok = false
					bad = "%s %s %s vs %s" % [str(g["label"]), f[0], str(g[f[0]]), str(j[f[1]])]
		_check(keys_ok, "%s covering keys + kinds == JS %s" % [name, bad])
		_check(worst < TOL * 4.0, "%s covering corners == JS (worst %.5f in)" % [name, worst])
		_check(dims_ok, "%s covering dims == JS %s" % [name, bad])
		var c2 := 0.0
		for i in mini(gs.size(), js_shapes.size()):
			for k in (gs[i]["corners_2d"] as Array).size():
				var jj: Dictionary = js_shapes[i]["corners2D"][k]
				c2 = maxf(c2, (gs[i]["corners_2d"][k] as Vector2).distance_to(Vector2(float(jj["s"]), float(jj["t"]))))
		_check(c2 < TOL * 4.0, "%s covering flat outlines == JS (worst %.5f)" % [name, c2])
	# --- shade ---
	var shade := LinkageShadeCloth.compute(beams, p, _upper_top(cov))
	var js_sh = a4.get("shade")
	var shade_on := bool(LinkageShadeCloth.config(p)["enabled"])
	_check((js_sh is Dictionary) == shade_on, "%s shade enabled as in JS" % name)
	if shade_on and js_sh is Dictionary:
		var jss: Array = js_sh["baseShapes"]
		var gss: Array = shade["shapes"]
		_check(gss.size() == jss.size(), "%s tarps %d == JS %d" % [name, gss.size(), jss.size()])
		var w2 := 0.0
		var dim2 := true
		for i in mini(gss.size(), jss.size()):
			for k in 4:
				w2 = maxf(w2, ((gss[i]["corners"][k] as Vector3) - g_anchor).distance_to(_v3(jss[i]["corners3D"][k]) - j_anchor))
			if absf(float(gss[i]["width_in"]) - float(jss[i]["widthIn"])) > TOL or absf(float(gss[i]["length_in"]) - float(jss[i]["lengthIn"])) > TOL:
				dim2 = false
		_check(w2 < TOL * 4.0, "%s tarp corners == JS (worst %.5f in)" % [name, w2])
		_check(dim2, "%s tarp sizes == JS" % name)
		_check(absf(float(shade["coverage_pct"]) - float(js_sh["summary"]["coveragePct"])) < 0.15,
			"%s roof coverage %s%% == JS %s%%" % [name, str(shade["coverage_pct"]), str(js_sh["summary"]["coveragePct"])])
		var jb: Array = js_sh["bom"]
		var gb := LinkageShadeCloth.bom_items(shade, p)
		_check(gb.size() == jb.size() and (gb.is_empty() or int(gb[0]["qty"]) == int(jb[0]["qty"])), "%s tarp BOM rows == JS" % name)
	# --- the cut plan ---
	var plan := LinkageCoveringPlan.compute(cov["shapes"] if cov_on else [], LinkageCoverings.config(p), deck)
	var jp = a4.get("plan")
	if jp is Dictionary:
		var gt: Dictionary = plan["totals"]
		var jt: Dictionary = jp["totals"]
		var tot_bad: Array = []
		for f in [["walls", "walls"], ["tables", "tables"], ["floor_sheets", "floorSheets"], ["fabric_bands", "fabricBands"],
				["sheets", "sheets"], ["full_sheets", "fullSheets"], ["cut_pieces", "cutPieces"], ["seams", "seams"],
				["grommets", "grommets"], ["fabric_panels", "fabricPanels"], ["warnings", "warnings"]]:
			if absf(float(gt[f[0]]) - float(jt[f[1]])) > 1e-6:
				tot_bad.append("%s %s vs %s" % [f[0], str(gt[f[0]]), str(jt[f[1]])])
		for f in [["plywood_area_in2", "plywoodAreaIn2", 0.6], ["stock_area_in2", "stockAreaIn2", 0.6],
				["batten_linear_in", "battenLinearIn", 0.3], ["fabric_yards", "fabricYards", 0.02], ["utilization", "utilization", 0.002]]:
			if absf(float(gt[f[0]]) - float(jt[f[1]])) > float(f[2]):
				tot_bad.append("%s %s vs %s" % [f[0], str(gt[f[0]]), str(jt[f[1]])])
		_check(tot_bad.is_empty(), "%s cut plan totals == JS %s" % [name, str(tot_bad)])
		var gw: Array = plan["walls"]
		var jw: Array = jp["walls"]
		var nest_ok := gw.size() == jw.size()
		for i in mini(gw.size(), jw.size()):
			var gn: Dictionary = gw[i]["nest"]
			var jn: Dictionary = jw[i]["nest"]
			if int(gn["sheet_count"]) != int(jn["sheetCount"]) or absf(float(gn["seam_count"]) - float(jn["seamCount"])) > 1e-6:
				nest_ok = false
		_check(nest_ok, "%s every wall nests on the same sheets as JS" % name)
		if jp.get("floor") is Dictionary:
			_check(not (plan["floor"] as Dictionary).is_empty() and int(plan["floor"]["nest"]["sheet_count"]) == int(jp["floor"]["sheetCount"]),
				"%s the deck nests on %d sheets as in JS" % [name, int(jp["floor"]["sheetCount"])])
		var gbi := LinkageCoveringPlan.bom_items(plan, p)
		var jbi: Array = jp["bom"]
		var bom_ok := gbi.size() == jbi.size()
		for i in mini(gbi.size(), jbi.size()):
			bom_ok = bom_ok and int(gbi[i]["qty"]) == int(jbi[i]["qty"]) and is_equal_approx(float(gbi[i]["unit_cost"]), float(jbi[i]["unit"]))
		_check(bom_ok, "%s enclosure BOM rows == JS (%d)" % [name, jbi.size()])
		# Every entry renders an SVG cut file.
		var svgs_ok := true
		for e in LinkageCoveringPlan.entries(plan):
			var svg := LinkageCoveringPlan.entry_svg(e, p)
			svgs_ok = svgs_ok and svg.begins_with("<?xml") and svg.contains("</svg>")
		_check(svgs_ok, "%s every cut-plan entry renders an SVG" % name)
	print("  %s: %d covering shapes, %d tarps, deck %s, %d sheets" % [name, (cov.get("shapes", []) as Array).size(),
		(shade.get("shapes", []) as Array).size(), "yes" if not deck.is_empty() else "no", int(plan["totals"]["sheets"])])


## LinkageBom's ENCLOSURE section = the cut plan's rows + the tarps' rows
## (bom.js enclosureItems), counted in the total and scaled by copies.
func _test_bom_enclosure() -> void:
	for name in ["starshade_hex", "constellation"]:
		var fx = _read_json("res://core/linkage/testdata/parity/%s.json" % name)
		var p := LinkageParams.new()
		p.from_config(_read_json("res://core/linkage/presets/ll_%s.json" % name))
		var bom := LinkageBom.compute(p)
		var one: Dictionary = bom["per_structure"]
		var want := (fx["a4"]["plan"]["bom"] as Array).size() + (fx["a4"]["shade"]["bom"] as Array).size()
		_check((one["enclosure_items"] as Array).size() == want,
			"%s BOM enclosure rows %d == JS %d" % [name, (one["enclosure_items"] as Array).size(), want])
		_check(is_equal_approx(float(bom["total_cost"]), float(bom["structure_cost"]) + float(bom["power_cost"]) + float(bom["enclosure_cost"])),
			"%s total = structure + power + enclosure" % name)
		var k := int(bom["copies"]["total"])
		_check(is_equal_approx(float(bom["enclosure_cost"]), k * float(one["enclosure_cost"])) and float(one["enclosure_cost"]) > 0.0,
			"%s enclosure cost x %d copies" % [name, k])


## The top of the upper wall / fabric bands (the tarps sit above them).
func _upper_top(cov: Dictionary) -> float:
	var top := NAN
	for sh in cov.get("shapes", []):
		if str(sh.get("band", "")) == "upper" or str(sh.get("band", "")) == "lower":
			top = float(sh["y_top"]) if is_nan(top) else maxf(top, float(sh["y_top"]))
	return top
