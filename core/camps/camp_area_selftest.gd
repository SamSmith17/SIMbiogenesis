extends SceneTree

## Headless self-test for painted camp areas (core/camps/): the household
## templates, CampLayoutGenerator, CampAreaLayer's paint/erase algebra and
## persistence, CampSubdivider, and CampAreaRuntime's per-area batches.
## Pure / offline (no imported art is loaded). Run --import first.
##   godot --headless --path . --script core/camps/camp_area_selftest.gd
## Exits 0 when all assertions pass, 1 otherwise.

## A Godot runtime error aborts the enclosing test function while the suite
## still prints PASS, so the check COUNT is pinned too.
const EXPECTED_CHECKS := 125

var _failures: int = 0
var _checks: int = 0


func _initialize() -> void:
	_test_templates_fit_cells()
	_test_heading_math()
	_test_places_without_roads()
	_test_determinism()
	_test_alignment()
	_test_containment_and_overlap()
	_test_grow_stability()
	_test_density()
	_test_auto_heading()
	_test_slope_and_exclusion()
	_test_layer_roundtrip()
	_test_paint_merge()
	_test_erase()
	_test_subdivide()
	_test_user_styles()
	_test_layers_layouts_edits()
	if _checks != EXPECTED_CHECKS:
		_failures += 1
		print("  FAIL: ran %d checks, expected %d (a test function aborted?)"
			% [_checks, EXPECTED_CHECKS])
	if _failures == 0:
		print("CAMP AREA SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("CAMP AREA SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
	# The runtime test needs nodes inside the tree, which only exists once the
	# first frame runs.
	process_frame.connect(_run_tree_tests, CONNECT_ONE_SHOT)


func _run_tree_tests() -> void:
	var before := _checks
	_test_runtime()
	const TREE_CHECKS := 8
	if _checks - before != TREE_CHECKS:
		_failures += 1
		print("  FAIL: runtime test ran %d checks, expected %d" % [_checks - before, TREE_CHECKS])
	if _failures == 0:
		print("CAMP AREA RUNTIME SELFTEST PASS  (%d checks total)" % _checks)
		quit(0)
	else:
		print("CAMP AREA RUNTIME SELFTEST FAIL  (%d failures)" % _failures)
		quit(1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


func _rect(x0: float, z0: float, x1: float, z1: float) -> PackedVector2Array:
	return PackedVector2Array([Vector2(x0, z0), Vector2(x1, z0), Vector2(x1, z1), Vector2(x0, z1)])


func _area(poly: PackedVector2Array, style: String = "mixed", extra: Dictionary = {}) -> Dictionary:
	var a := {"id": "t", "polygon": poly, "holes": [], "style": style, "density": 1.0,
		"seed": 4242, "heading_deg": 90.0, "align_jitter_deg": 5.0, "light_density": 1.0}
	a.merge(extra, true)
	return a


func _fp_key(fp: Dictionary) -> String:
	var c: Vector2 = fp["center"]
	return "%s|%.3f|%.3f|%.4f" % [fp["cls"], c.x, c.y, float(fp["angle"])]


# ---------------------------------------------------------------------------

## Every template must fit inside every style cell that uses it — that is what
## makes neighbouring households independent (and grow-stability true).
func _test_templates_fit_cells() -> void:
	var worst := ""
	var unknown := ""
	for sid in CampStyles.STYLE_ORDER:
		var st := CampStyles.style(sid)
		for tid in (st["templates"] as Dictionary).keys():
			if not CampStyles.TEMPLATES.has(tid):
				unknown += "%s/%s " % [sid, tid]
				continue
			var ext := CampStyles.template_half_extent(str(tid), 5.0)
			if ext.x * 2.0 > float(st["cell_u"]) + 1e-3 or ext.y * 2.0 > float(st["cell_v"]) + 1e-3:
				worst += "%s/%s needs %.2fx%.2f in %.1fx%.1f; " % [sid, tid, ext.x * 2.0,
					ext.y * 2.0, float(st["cell_u"]), float(st["cell_v"])]
	_check("every style template exists", unknown.is_empty(), unknown)
	_check("every template fits its style cell", worst.is_empty(), worst)
	var no_size := ""
	var no_mode := ""
	for tid in CampStyles.TEMPLATES.keys():
		for it: Dictionary in CampStyles.TEMPLATES[tid]:
			if not CampStyles.CLASS_SIZE.has(it["cls"]):
				no_size += str(it["cls"]) + " "
			if not CampStyles.CLASS_MODE.has(it["cls"]):
				no_mode += str(it["cls"]) + " "
	_check("every template class has a size", no_size.is_empty(), no_size)
	_check("every template class has a yaw mode", no_mode.is_empty(), no_mode)
	_check("style order lists every style",
		CampStyles.STYLE_ORDER.size() == CampStyles.STYLES.size())


func _test_heading_math() -> void:
	# Bearing 0 = north = -Z; 90 = east = +X.
	var north := CampLayoutGenerator.heading_to_angle(0.0)
	_check("bearing 0 runs along -Z", Vector2(cos(north), sin(north)).distance_to(Vector2(0, -1)) < 1e-5)
	var east := CampLayoutGenerator.heading_to_angle(90.0)
	_check("bearing 90 runs along +X", Vector2(cos(east), sin(east)).distance_to(Vector2(1, 0)) < 1e-5)
	var ok := true
	for deg in [0.0, 17.0, 45.0, 90.0, 133.0, 179.0]:
		var a := CampLayoutGenerator.heading_to_angle(deg)
		var back := CampLayoutGenerator.direction_to_heading(Vector2(cos(a), sin(a)))
		ok = ok and absf(back - deg) < 1e-3
		# The reverse direction is the same axis.
		var back2 := CampLayoutGenerator.direction_to_heading(-Vector2(cos(a), sin(a)))
		ok = ok and (absf(back2 - deg) < 1e-3 or absf(absf(back2 - deg) - 180.0) < 1e-3)
	_check("heading <-> direction round-trips as an axis", ok)
	_check("axis deviation folds 180", absf(CampLayoutGenerator.axis_deviation_deg(
		CampLayoutGenerator.heading_to_angle(40.0) + PI, 40.0)) < 1e-3)


## THE regression that motivates the module: BrcCampGenerator needs a street
## within plot depth, so a camp painted on open ground got nothing.
func _test_places_without_roads() -> void:
	var res := CampLayoutGenerator.generate(_area(_rect(0, 0, 120, 80)), {})
	var n := int(res["stats"]["structures"])
	_check("a roadless field fills", n > 60, "structures=%d" % n)
	_check("households counted", int(res["stats"]["households"]) > 20)
	_check("several classes used", (res["classes"] as Dictionary).size() >= 5,
		str((res["classes"] as Dictionary).keys()))
	_check("night lights emitted", (res["glow"] as Array).size() > 10)
	var all_styles := true
	for sid in CampStyles.STYLE_ORDER:
		var r := CampLayoutGenerator.generate(_area(_rect(0, 0, 120, 90), sid), {})
		all_styles = all_styles and int(r["stats"]["structures"]) > 10
	_check("every style fills a field", all_styles)


func _test_determinism() -> void:
	var a := CampLayoutGenerator.generate(_area(_rect(0, 0, 100, 70)), {})
	var b := CampLayoutGenerator.generate(_area(_rect(0, 0, 100, 70)), {})
	var same := (a["footprints"] as Array).size() == (b["footprints"] as Array).size()
	if same:
		for i in (a["footprints"] as Array).size():
			same = same and _fp_key(a["footprints"][i]) == _fp_key(b["footprints"][i])
	_check("two runs are identical", same)
	var c := CampLayoutGenerator.generate(_area(_rect(0, 0, 100, 70), "mixed", {"seed": 99}), {})
	var differs := (c["footprints"] as Array).size() != (a["footprints"] as Array).size()
	if not differs:
		for i in (a["footprints"] as Array).size():
			differs = differs or _fp_key(a["footprints"][i]) != _fp_key(c["footprints"][i])
	_check("a different seed is a different camp", differs)


## People park square to their neighbours: every vehicle (and rigid shade) sits
## within the jitter of the camp axis, and a whole row noses the same way.
func _test_alignment() -> void:
	for heading in [90.0, 37.0]:
		var res := CampLayoutGenerator.generate(
			_area(_rect(-150, -150, 150, 150), "rv_park", {"heading_deg": heading}), {})
		var worst := 0.0
		var vehicles := 0
		var row_dir: Dictionary = {}
		var mixed_rows := 0
		var phi := CampLayoutGenerator.heading_to_angle(heading)
		for fp: Dictionary in res["footprints"]:
			if CampStyles.class_mode(str(fp["cls"])) != CampStyles.ALIGNED:
				continue
			worst = maxf(worst, CampLayoutGenerator.axis_deviation_deg(float(fp["angle"]), heading))
			if not CampStyles.is_vehicle(str(fp["cls"])):
				continue
			vehicles += 1
			var forward := cos(float(fp["angle"]) - phi) > 0.0
			var row := int(fp["row"])
			if row_dir.has(row) and row_dir[row] != forward:
				mixed_rows += 1
			row_dir[row] = forward
		_check("heading %d: vehicles present" % int(heading), vehicles > 40, "n=%d" % vehicles)
		_check("heading %d: aligned within 5 deg" % int(heading), worst <= 5.0 + 1e-3,
			"worst=%.3f" % worst)
		_check("heading %d: one parking direction per row" % int(heading), mixed_rows == 0,
			"mixed=%d" % mixed_rows)
		var dirs := {}
		for k in row_dir.keys():
			dirs[row_dir[k]] = true
		_check("heading %d: rows face both ways across the camp" % int(heading), dirs.size() == 2)
	# The jitter is the area's own setting, and 0 means dead square.
	var tight := CampLayoutGenerator.generate(
		_area(_rect(0, 0, 150, 120), "rv_park", {"align_jitter_deg": 0.0}), {})
	var w := 0.0
	for fp: Dictionary in tight["footprints"]:
		if CampStyles.class_mode(str(fp["cls"])) == CampStyles.ALIGNED:
			w = maxf(w, CampLayoutGenerator.axis_deviation_deg(float(fp["angle"]), 90.0))
	_check("zero jitter parks dead square", w < 1e-3, "worst=%.4f" % w)


func _test_containment_and_overlap() -> void:
	# An L-shaped camp with a hole in it.
	var poly := PackedVector2Array([Vector2(0, 0), Vector2(140, 0), Vector2(140, 60),
		Vector2(70, 60), Vector2(70, 130), Vector2(0, 130)])
	var hole := _rect(20, 20, 50, 45)
	var res := CampLayoutGenerator.generate(
		_area(poly, "mixed", {"holes": [hole], "heading_deg": 20.0}), {})
	var fps: Array = res["footprints"]
	_check("L-shaped camp fills", fps.size() > 40, "n=%d" % fps.size())
	var outside := 0
	var in_hole := 0
	for fp: Dictionary in fps:
		for p in CampLayoutGenerator.footprint_corners(fp):
			if not Geometry2D.is_point_in_polygon(p, poly):
				outside += 1
			if Geometry2D.is_point_in_polygon(p, hole):
				in_hole += 1
	_check("every footprint corner is inside the camp", outside == 0, "outside=%d" % outside)
	_check("nothing stands in a hole", in_hole == 0, "in_hole=%d" % in_hole)
	var overlaps := 0
	for sid in CampStyles.STYLE_ORDER:
		var r := CampLayoutGenerator.generate(
			_area(_rect(0, 0, 130, 100), sid, {"heading_deg": 63.0}), {})
		var f: Array = r["footprints"]
		for i in f.size():
			for j in range(i + 1, f.size()):
				if CampLayoutGenerator.footprints_overlap(f[i], f[j]):
					overlaps += 1
	_check("no two footprints overlap in any style", overlaps == 0, "overlaps=%d" % overlaps)
	# SAT sanity: the test above is only as good as the predicate.
	var fa := {"center": Vector2.ZERO, "half": Vector2(4, 1), "angle": 0.0}
	var fb := {"center": Vector2(0, 1.5), "half": Vector2(4, 1), "angle": 0.0}
	var fc := {"center": Vector2(0, 2.5), "half": Vector2(4, 1), "angle": 0.0}
	var fd := {"center": Vector2(5.5, 0), "half": Vector2(4, 1), "angle": PI * 0.5}
	_check("SAT: overlapping rects overlap", CampLayoutGenerator.footprints_overlap(fa, fb))
	_check("SAT: separated rects do not", not CampLayoutGenerator.footprints_overlap(fa, fc))
	_check("SAT: a turned rect off the end is clear",
		not CampLayoutGenerator.footprints_overlap(fa, fd))


## Brushing a camp bigger must not move a single tent that is already standing.
func _test_grow_stability() -> void:
	var broken := ""
	for sid in CampStyles.STYLE_ORDER:
		var small := CampLayoutGenerator.generate(
			_area(_rect(0, 0, 80, 60), sid, {"heading_deg": 31.0}), {})
		var big := CampLayoutGenerator.generate(
			_area(_rect(-40, -30, 150, 120), sid, {"heading_deg": 31.0}), {})
		var have := {}
		for fp: Dictionary in big["footprints"]:
			have[_fp_key(fp)] = true
		var lost := 0
		for fp: Dictionary in small["footprints"]:
			if not have.has(_fp_key(fp)):
				lost += 1
		if lost > 0 or (big["footprints"] as Array).size() <= (small["footprints"] as Array).size():
			broken += "%s lost %d; " % [sid, lost]
	_check("growing a camp keeps every existing structure", broken.is_empty(), broken)


func _test_density() -> void:
	var sparse := CampLayoutGenerator.generate(
		_area(_rect(0, 0, 150, 120), "mixed", {"density": 0.3}), {})
	var dense := CampLayoutGenerator.generate(
		_area(_rect(0, 0, 150, 120), "mixed", {"density": 1.0}), {})
	var ns := int(sparse["stats"]["structures"])
	var nd := int(dense["stats"]["structures"])
	_check("density raises the count", nd > ns * 2, "sparse=%d dense=%d" % [ns, nd])
	var dark := CampLayoutGenerator.generate(
		_area(_rect(0, 0, 150, 120), "mixed", {"light_density": 0.0}), {})
	_check("light density 0 emits no lights", (dark["glow"] as Array).is_empty())
	_check("light density does not move structures",
		int(dark["stats"]["structures"]) == nd)


func _test_auto_heading() -> void:
	# A long strip with no road: laid out along the strip.
	var strip := PackedVector2Array([Vector2(0, 0), Vector2(200, 30), Vector2(196, 60), Vector2(-4, 30)])
	var along := CampLayoutGenerator.direction_to_heading(Vector2(200, 30))
	_check("no road: heading follows the longest edge",
		absf(CampLayoutGenerator.resolve_heading(strip, []) - along) < 0.5)
	# A road beside it wins.
	var road := {"points": PackedVector2Array([Vector2(-50, -20), Vector2(-50, 300)])}
	_check("a nearby road sets the heading",
		absf(CampLayoutGenerator.resolve_heading(_rect(-40, 0, 60, 40), [road]) - 0.0) < 0.5
		or absf(CampLayoutGenerator.resolve_heading(_rect(-40, 0, 60, 40), [road]) - 180.0) < 0.5)
	# A road far away does not.
	var far := {"points": PackedVector2Array([Vector2(900, -20), Vector2(900, 300)])}
	_check("a distant road is ignored",
		absf(CampLayoutGenerator.resolve_heading(_rect(0, 0, 100, 40), [far]) - 90.0) < 0.5)
	# heading_deg < 0 on the record means "resolve it".
	var res := CampLayoutGenerator.generate(
		_area(_rect(0, 0, 100, 40), "mixed", {"heading_deg": -1.0}), {"roads": [far]})
	_check("generate resolves an unset heading", absf(float(res["stats"]["heading_deg"]) - 90.0) < 0.5)


func _test_slope_and_exclusion() -> void:
	# Left half flat, right half a 30 % grade (16.7 deg): no vehicles there,
	# tents (limit 18 deg) still pitch.
	var ground := func(x: float, _z: float) -> float:
		return 0.0 if x < 60.0 else (x - 60.0) * 0.3
	var res := CampLayoutGenerator.generate(_area(_rect(0, 0, 130, 100)), {"ground_y_at": ground})
	var veh_on_slope := 0
	var tents_on_slope := 0
	for fp: Dictionary in res["footprints"]:
		if (fp["center"] as Vector2).x > 63.0:
			if CampStyles.is_vehicle(str(fp["cls"])):
				veh_on_slope += 1
			else:
				tents_on_slope += 1
	_check("vehicles refuse a 17 deg slope", veh_on_slope == 0, "n=%d" % veh_on_slope)
	_check("tents still pitch on it", tents_on_slope > 5, "n=%d" % tents_on_slope)
	_check("slope rejections are counted", int(res["stats"]["rejected_slope"]) > 0)
	var seated := true
	var tilted := false
	for cls in (res["classes"] as Dictionary).keys():
		for c: Dictionary in res["classes"][cls]:
			var p: Vector3 = c["pos"]
			seated = seated and absf(p.y - float(ground.call(p.x, p.z))) < 1e-4
			tilted = tilted or (c["up"] as Vector3).distance_to(Vector3.UP) > 1e-4
	_check("every structure sits on the ground callable", seated)
	# A gentle 5 % grade everywhere: vehicles park on it and tilt with it.
	var gentle := func(x: float, _z: float) -> float:
		return x * 0.05
	var res2 := CampLayoutGenerator.generate(_area(_rect(0, 0, 100, 80), "rv_park"),
		{"ground_y_at": gentle})
	var any_tilt := false
	for c: Dictionary in (res2["classes"] as Dictionary).get("rv", []):
		any_tilt = any_tilt or absf((c["up"] as Vector3).x + 0.05 / sqrt(1.0025)) < 1e-3
	_check("vehicles tilt with the ground", any_tilt and not tilted or any_tilt)
	# Exclusion: nothing in a band the callable forbids.
	var band := func(p: Vector2) -> bool:
		return p.x > 40.0 and p.x < 60.0
	var res3 := CampLayoutGenerator.generate(_area(_rect(0, 0, 130, 100)), {"is_excluded": band})
	var in_band := 0
	for fp: Dictionary in res3["footprints"]:
		for p in CampLayoutGenerator.footprint_corners(fp):
			if bool(band.call(p)):
				in_band += 1
	_check("excluded ground stays empty", in_band == 0 and int(res3["stats"]["rejected_excluded"]) > 0,
		"in_band=%d" % in_band)


func _test_layer_roundtrip() -> void:
	var layer := CampAreaLayer.create_empty()
	var id := layer.add(_rect(0, 0, 50, 40), {"style": "rv_park", "density": 0.6,
		"heading_deg": 200.0, "align_jitter_deg": 3.0, "light_density": 1.5,
		"name": "Kidsville", "group_id": "g1", "holes": [_rect(10, 10, 20, 20)], "seed": 77})
	_check("add returns an id", id == "camp_1")
	_check("heading is folded into 0..180", absf(float(layer.get_area(id)["heading_deg"]) - 20.0) < 1e-4)
	_check("degenerate polygons are refused", layer.add(_rect(0, 0, 1, 1), {}) == "")
	var path := "user://camp_area_selftest_tmp.json"
	_check("save succeeds", layer.save_to(path))
	var back := CampAreaLayer.create_empty()
	_check("load succeeds", back.load_from(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var a := layer.get_area(id)
	var b := back.get_area(id)
	var same := not b.is_empty()
	for k in ["name", "style", "density", "seed", "heading_deg", "heading_auto",
			"align_jitter_deg", "light_density", "group_id"]:
		same = same and str(a.get(k)) == str(b.get(k))
	same = same and (b.get("polygon", PackedVector2Array()) as PackedVector2Array).size() == 4
	same = same and (b.get("holes", []) as Array).size() == 1
	_check("every record key survives a file round-trip", same, str(b))
	_check("ids keep counting after a reload", back.add(_rect(100, 0, 150, 40), {}) == "camp_2")
	_check("area_at finds the camp but not its hole",
		layer.area_at(Vector2(40, 30)) == id and layer.area_at(Vector2(15, 15)) == ""
		and layer.area_at(Vector2(500, 500)) == "")
	var snap := layer.snapshot()
	layer.remove(id)
	layer.restore(snap)
	_check("snapshot/restore brings a deleted camp back", layer.index_of(id) == 0)


func _test_paint_merge() -> void:
	var layer := CampAreaLayer.create_empty()
	var r1 := layer.paint(_rect(0, 0, 40, 40), {"style": "mixed", "seed": 5})
	var r2 := layer.paint(_rect(30, 0, 80, 40), {"style": "mixed", "seed": 9})
	_check("an overlapping same-style stroke grows the camp",
		layer.areas.size() == 1 and r2["id"] == r1["id"])
	_check("the grown camp keeps its seed and covers both strokes",
		int(layer.areas[0]["seed"]) == 5
		and absf(CampAreaLayer.record_area(layer.areas[0]) - 3200.0) < 1.0,
		"area=%.1f" % CampAreaLayer.record_area(layer.areas[0]))
	var r3 := layer.paint(_rect(60, 0, 120, 40), {"style": "rv_park"})
	_check("a different style becomes its own camp", layer.areas.size() == 2 and r3["id"] != r1["id"])
	_check("and takes the ground it was painted over",
		absf(CampAreaLayer.record_area(layer.get_area(r1["id"])) - 2400.0) < 1.0
		and layer.area_at(Vector2(70, 20)) == r3["id"],
		"area=%.1f" % CampAreaLayer.record_area(layer.get_area(r1["id"])))
	var r4 := layer.paint(_rect(300, 300, 340, 340), {"style": "mixed"})
	_check("a disjoint stroke is a new camp", layer.areas.size() == 3 and r4["id"] != r1["id"])


func _test_erase() -> void:
	var layer := CampAreaLayer.create_empty()
	var id := layer.add(_rect(0, 0, 100, 40), {"seed": 31, "style": "tent_village"})
	# A cut straight across splits it in two.
	var res := layer.erase(_rect(45, -10, 55, 50))
	_check("a cut across makes two camps", layer.areas.size() == 2, "n=%d" % layer.areas.size())
	var both_seeded := true
	var total := 0.0
	for rec: Dictionary in layer.areas:
		both_seeded = both_seeded and int(rec["seed"]) == 31 and str(rec["style"]) == "tent_village"
		total += CampAreaLayer.record_area(rec)
	_check("both halves keep the seed and style", both_seeded)
	_check("the erased strip is gone from the total", absf(total - 3600.0) < 1.0, "total=%.1f" % total)
	_check("erase reports what changed", (res["changed"] as Array).size() == 2)
	# A cut in the middle of one half leaves a hole.
	layer.erase(_rect(10, 10, 30, 30))
	var holed := layer.get_area(layer.area_at(Vector2(5, 5)))
	_check("an interior cut becomes a hole", (holed.get("holes", []) as Array).size() == 1
		and layer.area_at(Vector2(20, 20)) == "")
	# Erasing a whole camp removes it.
	var gone := layer.erase(_rect(-10, -10, 46, 50))
	_check("erasing a whole camp removes it",
		layer.areas.size() == 1 and (gone["removed"] as Array).size() == 1)
	_check("the original id survives on one piece or is reported",
		layer.index_of(id) >= 0 or (gone["removed"] as Array).has(id))


func _test_subdivide() -> void:
	var zone := _rect(0, 0, 200, 120)
	var plots := CampSubdivider.subdivide(zone, 90.0, 20.0, 15.0, 5.0)
	_check("a zone splits into many plots", plots.size() >= 30, "n=%d" % plots.size())
	var clash := 0
	var outside := 0
	var names := {}
	for i in plots.size():
		names[plots[i]["name"]] = true
		for p in plots[i]["polygon"]:
			if p.x < -0.01 or p.x > 200.01 or p.y < -0.01 or p.y > 120.01:
				outside += 1
		for j in range(i + 1, plots.size()):
			if CampAreaLayer._overlaps(plots[i]["polygon"], plots[j]["polygon"]):
				clash += 1
	_check("plots are pairwise disjoint", clash == 0, "clash=%d" % clash)
	_check("plots stay inside the zone", outside == 0)
	_check("plot names are unique (A1, A2, B1...)", names.size() == plots.size()
		and names.has("A1") and names.has("B1"))
	var used := 0.0
	for pl in plots:
		used += CampAreaLayer.polygon_area(pl["polygon"])
	_check("lanes are left empty", used < 200.0 * 120.0 * 0.9 and used > 200.0 * 120.0 * 0.5,
		"used=%.0f" % used)
	# A triangle clips its edge plots; slivers are dropped.
	var tri := PackedVector2Array([Vector2(0, 0), Vector2(120, 0), Vector2(0, 90)])
	var small_ok := true
	for pl in CampSubdivider.subdivide(tri, 90.0, 20.0, 15.0, 5.0):
		small_ok = small_ok and CampAreaLayer.polygon_area(pl["polygon"]) >= 20.0 * 15.0 * 0.3 - 0.01
	_check("slivers under 30 % of a plot are dropped", small_ok)
	# A plot (group_id set) fits its lattice to itself: it must hold more than
	# the same rectangle laid out on the world lattice, and still stay inside.
	var plot_poly := _rect(3.0, 4.0, 33.0, 26.0)
	var loose := CampLayoutGenerator.generate(_area(plot_poly, "mixed"), {})
	var fitted := CampLayoutGenerator.generate(
		_area(plot_poly, "mixed", {"group_id": "zone_1"}), {})
	var escaped := 0
	for fp: Dictionary in fitted["footprints"]:
		for p in CampLayoutGenerator.footprint_corners(fp):
			if not Geometry2D.is_point_in_polygon(p, plot_poly):
				escaped += 1
	_check("a plot fits its lattice to itself",
		int(fitted["stats"]["households"]) > int(loose["stats"]["households"])
		and int(fitted["stats"]["households"]) >= 4 and escaped == 0,
		"fitted=%d loose=%d escaped=%d" % [int(fitted["stats"]["households"]),
			int(loose["stats"]["households"]), escaped])
	_check("row letters run past Z", CampSubdivider.row_letters(0) == "A"
		and CampSubdivider.row_letters(25) == "Z" and CampSubdivider.row_letters(26) == "AA")


## The Tune-look layer: a player's style edits and added models (CampStyleStore
## -> CampStyles.set_user_layer). The shipped tables are the identity.
func _test_user_styles() -> void:
	var poly := _rect(0, 0, 150, 110)
	CampStyles.clear_user_layer()
	var baseline := CampLayoutGenerator.generate(_area(poly, "tent_village"), {})

	# normalize is the file's gatekeeper.
	var raw := {"styles": {
			"tent_village": {"fill": 0.5, "templates": {"rv_site": 3.0, "nope": 2.0, "m:u_ghost": 1.0}},
			"not_a_style": {"fill": 0.2}},
		"models": {
			"u_bus": {"model_id": "bus", "label": "Bus", "mode": 0, "size": [14.0, 3.2, 2.6], "tris": 90000},
			"u_bad": {"model_id": "x", "size": [0.0, 1.0, 1.0]}}}
	var norm := CampStyleStore.normalize(raw)
	_check("unknown styles are dropped", not (norm["styles"] as Dictionary).has("not_a_style"))
	_check("unknown templates and orphan model templates are dropped",
		(norm["styles"]["tent_village"]["templates"] as Dictionary).keys() == ["rv_site"])
	_check("malformed models are dropped", (norm["models"] as Dictionary).keys() == ["u_bus"])
	var path := "user://camp_style_selftest_tmp.json"
	_check("styles save", CampStyleStore.save_data(norm, path))
	var back := CampStyleStore.load_data(path)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_check("styles survive a file round-trip",
		JSON.stringify(back) == JSON.stringify(norm), JSON.stringify(back))
	_check("a missing file is the empty layer",
		(CampStyleStore.load_data("user://camp_style_no_such_file.json")["styles"] as Dictionary).is_empty())

	# A mix edit changes what is laid out: rv_site joins the tent village.
	CampStyleStore.apply(norm)
	var with_rv := CampLayoutGenerator.generate(_area(poly, "tent_village"), {})
	_check("a household added to the mix appears", (with_rv["classes"] as Dictionary).has("rv")
		and not (baseline["classes"] as Dictionary).has("rv"))
	_check("the user fill thins the camp",
		int(with_rv["stats"]["households"]) < int(baseline["stats"]["households"]))

	# A player-added model: its own class, and the cell grows to hold it.
	var data := CampStyleStore.empty()
	var cid := CampStyleStore.add_model(data, "bus", "Bus",
		{"size": Vector3(14.0, 3.2, 2.6), "tris": 90000})
	_check("a long model defaults to aligned parking", cid == "u_bus"
		and int(data["models"][cid]["mode"]) == CampStyles.ALIGNED)
	data["styles"]["tent_village"] = {"templates": {"m:u_bus": 4.0}}
	CampStyleStore.apply(data)
	var st := CampStyles.style("tent_village")
	_check("the style's cell grows to fit the largest household",
		float(st["cell_u"]) >= 14.0 * 1.08 and float(st["cell_u"]) > float(CampStyles.base_style("tent_village")["cell_u"]),
		"cell_u=%.2f" % float(st["cell_u"]))
	var bus_camp := CampLayoutGenerator.generate(_area(poly, "tent_village", {"heading_deg": 40.0}), {})
	var buses: Array = (bus_camp["classes"] as Dictionary).get("u_bus", [])
	_check("the added model is placed", buses.size() > 3, "n=%d" % buses.size())
	var overlaps := 0
	var worst := 0.0
	var f: Array = bus_camp["footprints"]
	for i in f.size():
		if str(f[i]["cls"]) == "u_bus":
			worst = maxf(worst, CampLayoutGenerator.axis_deviation_deg(float(f[i]["angle"]), 40.0))
		for j in range(i + 1, f.size()):
			if CampLayoutGenerator.footprints_overlap(f[i], f[j]):
				overlaps += 1
	_check("nothing overlaps with a 14 m model in the mix", overlaps == 0, "overlaps=%d" % overlaps)
	_check("the added model parks within the jitter", worst <= 5.0 + 1e-3, "worst=%.2f" % worst)
	var small := CampLayoutGenerator.generate(_area(_rect(0, 0, 90, 70), "tent_village", {"heading_deg": 40.0}), {})
	var big := CampLayoutGenerator.generate(_area(_rect(-50, -40, 170, 130), "tent_village", {"heading_deg": 40.0}), {})
	var have := {}
	for fp: Dictionary in big["footprints"]:
		have[_fp_key(fp)] = true
	var lost := 0
	for fp: Dictionary in small["footprints"]:
		if not have.has(_fp_key(fp)):
			lost += 1
	_check("growing a camp is still stable with user models", lost == 0, "lost=%d" % lost)

	# Spacing, and the never-empty rule.
	CampStyleStore.apply({"styles": {"tent_village": {"spacing": 2.0}}, "models": {}})
	var spaced := CampLayoutGenerator.generate(_area(poly, "tent_village"), {})
	_check("spacing spreads the camp out",
		int(spaced["stats"]["households"]) * 2 < int(baseline["stats"]["households"]))
	var zeros := {}
	for tid in (CampStyles.base_style("tent_village")["templates"] as Dictionary).keys():
		zeros[tid] = 0.0
	CampStyleStore.apply({"styles": {"tent_village": {"templates": zeros}}, "models": {}})
	_check("a style with every household switched off falls back to its shipped mix",
		not (CampStyles.style("tent_village")["templates"] as Dictionary).is_empty())

	# Removing a model takes it out of every style.
	CampStyleStore.remove_model(data, "u_bus")
	_check("removing a model removes its share",
		(data["models"] as Dictionary).is_empty()
		and not (data["styles"]["tent_village"]["templates"] as Dictionary).has("m:u_bus"))

	# Warnings are words, never refusals.
	_check("a very detailed model is flagged",
		CampStyleStore.model_warnings(Vector3(5, 2, 2), 90000).size() == 1)
	_check("a huge model is flagged for its size too",
		CampStyleStore.model_warnings(Vector3(20, 4, 3), 90000).size() == 2)
	_check("an ordinary model draws no warning",
		CampStyleStore.model_warnings(Vector3(5, 2, 2), 2000).is_empty())
	var cheap := CampStyleStore.layout_cost({"camping_tent": 200}, {"camping_tent": 6}, 10000.0)
	var heavy := CampStyleStore.layout_cost({"u_bus": 60, "camping_tent": 100},
		{"u_bus": 90000, "camping_tent": 6}, 10000.0)
	_check("a light layout has no cost warning", (cheap["warnings"] as Array).is_empty())
	_check("a heavy layout warns and names the culprit", (heavy["warnings"] as Array).size() == 1
		and str(heavy["warnings"][0]).contains("u_bus"), str(heavy["warnings"]))

	# Clearing the layer is the identity: byte-for-byte the shipped camp.
	CampStyles.clear_user_layer()
	var again := CampLayoutGenerator.generate(_area(poly, "tent_village"), {})
	var same := (again["footprints"] as Array).size() == (baseline["footprints"] as Array).size()
	if same:
		for i in (again["footprints"] as Array).size():
			same = same and _fp_key(again["footprints"][i]) == _fp_key(baseline["footprints"][i])
	_check("with no user edits the shipped styles are untouched", same)


## Scopes (global / layout / map / camp), named layouts, variation knobs and
## per-element hand edits.
func _test_layers_layouts_edits() -> void:
	var poly := _rect(0, 0, 140, 100)
	CampStyles.clear_user_layer()

	# --- the stack: global < layout < map < camp --------------------------
	var data := CampStyleStore.empty()
	data["styles"]["mixed"] = {"lane_w": 2.0, "fill": 0.6}
	var vid := CampStyleStore.add_variant(data, "mixed", "Sound camp", {"lane_w": 9.0})
	CampStyleStore.apply(data)
	_check("a new layout gets an id and a name", vid == "v1"
		and CampStyles.variant_name("mixed", vid) == "Sound camp")
	var a := {"style": "mixed"}
	_check("global edit applies", is_equal_approx(float(CampStyles.style_for_area(a)["lane_w"]), 2.0))
	a["variant"] = vid
	_check("the camp's layout overrides the global edit",
		is_equal_approx(float(CampStyles.style_for_area(a)["lane_w"]), 9.0)
		and is_equal_approx(float(CampStyles.style_for_area(a)["fill"]), 0.6))
	var map_styles := {"mixed": {"lane_w": 4.0}}
	_check("the map's edit overrides the layout",
		is_equal_approx(float(CampStyles.style_for_area(a, map_styles)["lane_w"]), 4.0))
	a["style_override"] = {"lane_w": 12.0}
	_check("the camp's own override wins",
		is_equal_approx(float(CampStyles.style_for_area(a, map_styles)["lane_w"]), 12.0))
	_check("an unknown layout id is just the style",
		is_equal_approx(float(CampStyles.style_for_area({"style": "mixed", "variant": "gone"})["lane_w"]), 2.0))
	var merged := CampStyleStore.merge_entry({"fill": 0.5, "templates": {"rv_site": 1.0}},
		{"lane_w": 3.0, "templates": {"car_tent": 2.0}})
	_check("merging entries keeps both mixes", (merged["templates"] as Dictionary).size() == 2
		and merged.has("fill") and merged.has("lane_w"))

	# --- layouts are mixed by chance, deterministically -------------------
	var picks := {}
	for s in 400:
		var p := CampStyles.pick_variant("mixed", s * 7919)
		picks[p] = int(picks.get(p, 0)) + 1
	_check("new camps draw both the default and the layout",
		int(picks.get("", 0)) > 120 and int(picks.get(vid, 0)) > 120, str(picks))
	_check("the draw is a pure function of the seed",
		CampStyles.pick_variant("mixed", 4242) == CampStyles.pick_variant("mixed", 4242))
	(data["styles"]["mixed"] as Dictionary)["default_weight"] = 0.0
	CampStyleStore.apply(data)
	var only := true
	for s in 60:
		only = only and CampStyles.pick_variant("mixed", s) == vid
	_check("a default chance of 0 always draws a layout", only)
	_check("a style with no layouts draws the default", CampStyles.pick_variant("rv_park", 5) == "")
	var back := CampStyleStore.normalize(JSON.parse_string(JSON.stringify(data)))
	_check("layouts survive the file codec",
		(back["styles"]["mixed"]["variants"] as Array).size() == 1
		and str(back["styles"]["mixed"]["variants"][0]["name"]) == "Sound camp"
		and is_equal_approx(float(back["styles"]["mixed"]["default_weight"]), 0.0))

	# --- a camp record carries layout, override, edits; the layer, map styles
	var layer := CampAreaLayer.create_empty()
	var id := layer.add(poly, {"style": "mixed", "seed": 3})
	_check("a new camp is dealt a layout and keeps it", str(layer.get_area(id)["variant"]) == vid)
	layer.update(id, {"style_override": {"fill": 0.4, "bogus": 1, "templates": {"rv_site": 5.0, "nope": 1.0}},
		"edits": {"0:0:0": {"yaw_deg": 90.0}, "1:0:0": {"removed": true}, "2:0:0": {"yaw_deg": 0.0, "scale": 1.0}}})
	layer.map_styles["mixed"] = {"lane_w": 4.0}
	var rec := layer.get_area(id)
	_check("a camp override is cleaned", (rec["style_override"] as Dictionary).keys().size() == 2
		and (rec["style_override"]["templates"] as Dictionary).keys() == ["rv_site"])
	_check("no-op element edits are dropped", (rec["edits"] as Dictionary).size() == 2)
	var copy := CampAreaLayer.create_empty()
	copy.deserialize(JSON.parse_string(JSON.stringify(layer.serialize())))
	var rec2 := copy.get_area(id)
	_check("layout, override, edits and map styles survive a save",
		str(rec2["variant"]) == vid and JSON.stringify(rec2["style_override"]) == JSON.stringify(rec["style_override"])
		and JSON.stringify(rec2["edits"]) == JSON.stringify(rec["edits"])
		and is_equal_approx(float(copy.map_styles["mixed"]["lane_w"]), 4.0))
	CampStyles.clear_user_layer()

	# --- per-element hand edits ------------------------------------------
	var base := CampLayoutGenerator.generate(_area(poly, "rv_park"), {})
	var first: Dictionary = (base["classes"]["rv"] as Array)[0]
	var key := str(first["key"])
	var turned := CampLayoutGenerator.generate(
		_area(poly, "rv_park", {"edits": {key: {"yaw_deg": 90.0, "scale": 1.5}}}), {})
	var hit := {}
	var others_same := true
	var base_by_key := {}
	for cls in (base["classes"] as Dictionary).keys():
		for it: Dictionary in base["classes"][cls]:
			base_by_key[it["key"]] = it
	for cls in (turned["classes"] as Dictionary).keys():
		for it: Dictionary in turned["classes"][cls]:
			if str(it["key"]) == key:
				hit = it
			else:
				var o: Dictionary = base_by_key.get(it["key"], {})
				others_same = others_same and not o.is_empty() \
					and is_equal_approx(float(o["yaw"]), float(it["yaw"])) \
					and (o["pos"] as Vector3).is_equal_approx(it["pos"])
	_check("a hand edit turns and resizes exactly that element", not hit.is_empty()
		and absf(angle_difference(float(hit["yaw"]), float(first["yaw"]) - PI * 0.5)) < 1e-4
		and is_equal_approx(float(hit["scale"]), float(first["scale"]) * 1.5))
	_check("and nothing else moves",
		others_same and int(turned["stats"]["structures"]) == int(base["stats"]["structures"]))
	var removed := CampLayoutGenerator.generate(
		_area(poly, "rv_park", {"edits": {key: {"removed": true}}}), {})
	_check("a removed element is gone and only it",
		int(removed["stats"]["structures"]) == int(base["stats"]["structures"]) - 1
		and int(removed["stats"]["households"]) == int(base["stats"]["households"]))

	# --- variation knobs --------------------------------------------------
	var strict := CampLayoutGenerator.generate(_area(poly, "tent_village",
		{"style_override": {"pos_jitter": 0.0, "scale_var": 0.0, "loose_jitter_deg": 0.0}}), {})
	var st := CampStyles.style_for_area({"style": "tent_village"})
	var all_unit := true
	var all_square := true
	for cls in (strict["classes"] as Dictionary).keys():
		for it: Dictionary in strict["classes"][cls]:
			all_unit = all_unit and is_equal_approx(float(it["scale"]), 1.0)
	for fp: Dictionary in strict["footprints"]:
		if CampStyles.class_mode(str(fp["cls"])) == CampStyles.LOOSE:
			all_square = all_square and CampLayoutGenerator.axis_deviation_deg(float(fp["angle"]), 90.0) < 1e-3
	_check("size spread 0 makes every element its nominal size", all_unit)
	_check("tent turn 0 pitches tents square", all_square)
	var loose_dev := 0.0
	var wild := CampLayoutGenerator.generate(_area(poly, "tent_village",
		{"style_override": {"loose_jitter_deg": 60.0, "scale_var": 2.0}}), {})
	var max_scale := 0.0
	for fp: Dictionary in wild["footprints"]:
		if CampStyles.class_mode(str(fp["cls"])) == CampStyles.LOOSE:
			loose_dev = maxf(loose_dev, CampLayoutGenerator.axis_deviation_deg(float(fp["angle"]), 90.0))
	for cls in (wild["classes"] as Dictionary).keys():
		for it: Dictionary in wild["classes"][cls]:
			max_scale = maxf(max_scale, float(it["scale"]))
	_check("more variation really varies more", loose_dev > 30.0 and max_scale > 1.09,
		"dev=%.1f scale=%.3f" % [loose_dev, max_scale])
	var wild_overlaps := 0
	var wf: Array = wild["footprints"]
	for i in wf.size():
		for j in range(i + 1, wf.size()):
			if CampLayoutGenerator.footprints_overlap(wf[i], wf[j]):
				wild_overlaps += 1
	_check("the plot grows with the size spread, so nothing overlaps", wild_overlaps == 0
		and float(CampStyles.style_for_area({"style": "tent_village",
			"style_override": {"scale_var": 2.0}})["max_scale"]) > float(st["max_scale"]),
		"overlaps=%d" % wild_overlaps)

	# --- the studio's flat preview ---------------------------------------
	var hill := func(x: float, _z: float) -> float:
		return x * 0.05
	var flat := CampLayoutGenerator.generate(_area(poly, "rv_park"), {"ground_y_at": hill, "flatten": true})
	var real := CampLayoutGenerator.generate(_area(poly, "rv_park"), {"ground_y_at": hill})
	var on_zero := true
	for cls in (flat["classes"] as Dictionary).keys():
		for it: Dictionary in flat["classes"][cls]:
			on_zero = on_zero and is_zero_approx((it["pos"] as Vector3).y) and (it["up"] as Vector3) == Vector3.UP
	_check("the flat preview places the same elements on y = 0", on_zero
		and int(flat["stats"]["structures"]) == int(real["stats"]["structures"]))

	# --- click picking ----------------------------------------------------
	var items: Array = base["classes"]["rv"]
	var target: Dictionary = items[items.size() / 2]
	var tp: Vector3 = target["pos"]
	var from := tp + Vector3(0.3, 30.0, 0.2)
	_check("a ray down onto an element picks it",
		CampLayoutGenerator.pick_item_on_ray(items, from, (tp + Vector3(0, 1, 0) - from).normalized()) == str(target["key"]))
	_check("a ray at empty ground picks nothing",
		CampLayoutGenerator.pick_item_on_ray(items, Vector3(-500, 30, -500), Vector3.DOWN) == "")
	var near: Dictionary = {"key": "near", "pos": Vector3(0, 0, 0), "yaw": 0.0, "size": Vector3(2, 2, 2)}
	var far: Dictionary = {"key": "far", "pos": Vector3(0, 0, -10), "yaw": 0.0, "size": Vector3(2, 2, 2)}
	_check("the nearest element along the ray wins", CampLayoutGenerator.pick_item_on_ray(
		[far, near], Vector3(0, 1, 20), Vector3(0, 0, -1)) == "near")


# ---------------------------------------------------------------------------

func _test_runtime() -> void:
	var rt := CampAreaRuntime.new()
	rt.setup(null, false)
	root.add_child(rt)
	_check("the node is not named Camps* (the legacy sweep frees those)",
		String(rt.name) == "PaintedCamps" and not String(rt.name).begins_with("Camps"))
	var layer := CampAreaLayer.create_empty()
	var a := layer.add(_rect(0, 0, 90, 70), {"style": "rv_park", "heading_deg": 90.0})
	var b := layer.add(_rect(200, 0, 280, 60), {"style": "tent_village", "heading_deg": 90.0})
	rt.sync(layer, {})
	_check("one node per camp", rt.has_area(a) and rt.has_area(b))
	var na := rt.area_structure_count(a)
	_check("structures are counted per camp and in total",
		na > 20 and rt.structure_count() == na + rt.area_structure_count(b))
	var rvs := rt.area_class_transforms(a, "rv")
	var aligned := not rvs.is_empty()
	for xf: Transform3D in rvs:
		# Heading 90 = +X: the mesh's long (local X) axis must lie along world X.
		aligned = aligned and absf(xf.basis.x.normalized().z) <= sin(deg_to_rad(5.0)) + 1e-4
	_check("built RV transforms are aligned to the heading", aligned, "n=%d" % rvs.size())
	var mmi := rt.get_node_or_null("Area_%s/Class_rv_MM" % a) as MultiMeshInstance3D
	_check("batches carry a build-time visibility range",
		mmi != null and mmi.visibility_range_end > 0.0)
	rt.refresh_glow_now()
	_check("one shared glow batch + light pool",
		rt.get_node_or_null("CampGlow_MM") != null and rt.get_node_or_null("CampLightPool") != null)
	# Rebuilding one camp leaves the other's node untouched.
	var other := rt.get_node("Area_%s" % b)
	rt.rebuild_area(layer.get_area(a), {})
	_check("rebuilding one camp does not touch another",
		is_instance_valid(other) and other.get_parent() == rt and rt.area_structure_count(a) == na)
	layer.remove(a)
	rt.sync(layer, {})
	_check("a deleted camp's node is removed", not rt.has_area(a) and rt.has_area(b))
	rt.queue_free()
