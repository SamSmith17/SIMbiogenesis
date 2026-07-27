extends SceneTree

## Offline watershed self-test (synthetic DEM: hill + pit).
## Run with:
##   godot --headless --path . --script core/terrain/watershed_selftest.gd

var _failures: int = 0
var _checks: int = 0


func _initialize() -> void:
	_test_hill_drain()
	_test_pit_basin()
	_test_flow_path()
	_test_upstream_cells()
	_test_analyze_local()
	_test_catchment_lph()
	_test_sculpt_ops()
	_test_trace_downhill()
	if _failures == 0:
		print("WATERSHED SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("WATERSHED SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _check(name: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if ok:
		return
	_failures += 1
	if detail.is_empty():
		print("  FAIL: %s" % name)
	else:
		print("  FAIL: %s — %s" % [name, detail])


func _approx(a: float, b: float, tol: float) -> bool:
	return absf(a - b) <= tol


## Peak at centre; edges lower → centre flows outward; rim cells accumulate more.
func _test_hill_drain() -> void:
	var res := 9
	var heights := PackedFloat32Array()
	heights.resize(res * res)
	var cx := 4
	var cy := 4
	for r in res:
		for c in res:
			var dx := float(c - cx)
			var dy := float(r - cy)
			heights[r * res + c] = 100.0 - sqrt(dx * dx + dy * dy)
	var a := Watershed.analyze(heights, res, 80.0)
	_check("hill analyze res", a.res == res)
	_check("hill has basins", a.basin_count >= 1, "count=%d" % a.basin_count)
	var peak_acc := a.accumulation[cy * res + cx]
	_check("peak accumulation is 1 cell", _approx(peak_acc, 1.0, 1e-5),
		"got %f" % peak_acc)
	# A corner should receive more flow than the peak.
	var corner_acc := a.accumulation[0]
	_check("corner accumulates more than peak", corner_acc > peak_acc,
		"corner=%f peak=%f" % [corner_acc, peak_acc])
	var up_area := Watershed.upstream_area_m2(a, 0, 0)
	_check("upstream area positive", up_area > 0.0, "got %f" % up_area)
	_check("cell area ~ (10m)^2", _approx(a.cell_area_m2, 100.0, 0.1),
		"got %f" % a.cell_area_m2)


## Closed depression at centre → single basin; flow path ends at pit.
func _test_pit_basin() -> void:
	var res := 7
	var heights := PackedFloat32Array()
	heights.resize(res * res)
	for r in res:
		for c in res:
			heights[r * res + c] = 50.0
	# Raised rim, deep pit at centre.
	for r in res:
		for c in res:
			if r == 0 or c == 0 or r == res - 1 or c == res - 1:
				heights[r * res + c] = 60.0
	heights[3 * res + 3] = 10.0
	heights[2 * res + 3] = 30.0
	heights[3 * res + 2] = 30.0
	heights[4 * res + 3] = 30.0
	heights[3 * res + 4] = 30.0
	var a := Watershed.analyze(heights, res, 60.0)
	_check("pit basin count >= 1", a.basin_count >= 1, "count=%d" % a.basin_count)
	var pit_id := Watershed.basin_at(a, 3, 3)
	_check("pit has basin id", pit_id >= 0, "id=%d" % pit_id)
	var mid_id := Watershed.basin_at(a, 3, 2)
	_check("neighbour shares pit basin", mid_id == pit_id,
		"mid=%d pit=%d" % [mid_id, pit_id])
	var path := Watershed.flow_path(a, 3, 2)
	_check("flow path non-empty", path.size() >= 2, "len=%d" % path.size())
	var last := path[path.size() - 1]
	var pit_w := TerrainSculpt.cell_to_world(3, 3, res, 60.0)
	_check("flow path ends near pit", last.distance_to(pit_w) < 1.0,
		"last=%s pit=%s" % [last, pit_w])


func _test_flow_path() -> void:
	var res := 5
	var heights := PackedFloat32Array()
	heights.resize(res * res)
	# Monotone ramp: west high → east low.
	for r in res:
		for c in res:
			heights[r * res + c] = float(res - 1 - c) * 10.0
	var a := Watershed.analyze(heights, res, 40.0)
	var path := Watershed.flow_path(a, 0, 2)
	_check("ramp path length", path.size() >= 3, "len=%d" % path.size())
	# X should generally increase toward the low side.
	if path.size() >= 2:
		_check("ramp drains eastward", path[path.size() - 1].x > path[0].x,
			"start=%s end=%s" % [path[0], path[path.size() - 1]])


## Bowl: rim high, centre pit — every interior cell drains to the pour point.
func _test_upstream_cells() -> void:
	var res := 9
	var heights := PackedFloat32Array()
	heights.resize(res * res)
	var cx := 4
	var cy := 4
	for r in res:
		for c in res:
			var dx := float(c - cx)
			var dy := float(r - cy)
			heights[r * res + c] = 10.0 + sqrt(dx * dx + dy * dy) * 5.0
	var a := Watershed.analyze(heights, res, 80.0)
	var cells := Watershed.upstream_cells(a, cx, cy)
	_check("upstream includes pour", cells.size() >= 1, "n=%d" % cells.size())
	var seeds := PackedInt32Array()
	seeds.append(cy * a.res + cx)
	var multi := Watershed.upstream_cells_multi(a, seeds)
	_check("upstream_multi matches single", multi.size() == cells.size(),
			"multi=%d single=%d" % [multi.size(), cells.size()])
	var has_pour := false
	var pour_idx := cy * res + cx
	for i in cells:
		if int(i) == pour_idx:
			has_pour = true
			break
	_check("pour cell in upstream set", has_pour)
	# Most of the grid should contribute to the closed bowl.
	_check("upstream covers most of bowl", cells.size() >= res * res / 2,
		"n=%d / %d" % [cells.size(), res * res])
	var area := float(cells.size()) * a.cell_area_m2
	_check("upstream area matches cell count",
			_approx(area, Watershed.upstream_area_m2(a, cx, cy), a.cell_area_m2 * 2.0),
			"mask=%f accum=%f" % [area, Watershed.upstream_area_m2(a, cx, cy)])
	var poly := Watershed.upstream_polygon_world(a, cells)
	_check("upstream polygon has ring", poly.size() >= 3, "n=%d" % poly.size())
	var poly_area := BuildingBuilder.footprint_area_m2(poly)
	_check("upstream poly area positive", poly_area > a.cell_area_m2,
			"got %f" % poly_area)


func _test_analyze_local() -> void:
	# Flat plane with a pit at world (20, -10).
	var pit := Vector2(20.0, -10.0)
	var height_at := func(x: float, z: float) -> float:
		var d := Vector2(x, z).distance_to(pit)
		return 50.0 + d * 0.5
	var a := Watershed.analyze_local(height_at, pit, 40.0, 33)
	_check("local analyze res", a.res == 33)
	_check("local origin set", a.origin_xz.distance_to(pit) < 0.01,
			"got %s" % a.origin_xz)
	var cell := Watershed.world_to_cell(a, pit.x, pit.y)
	var cells := Watershed.upstream_cells(a, cell.x, cell.y)
	_check("local upstream non-empty", cells.size() >= 5, "n=%d" % cells.size())
	var w := Watershed.cell_to_world(a, cell.x, cell.y)
	_check("local cell_to_world near pit", w.distance_to(pit) < a.extent_m / float(a.res),
			"w=%s pit=%s" % [w, pit])


## Catchment rain → L/h (same formula as ResourceFlowEngine._process_catchment).
func _test_catchment_lph() -> void:
	var area_m2 := 10000.0
	var runoff := 0.35
	var rain_mmh := 4.0
	var capture_lph := area_m2 * runoff * rain_mmh
	_check("watershed capture L/h", _approx(capture_lph, 14000.0, 0.01),
			"got %f" % capture_lph)
	_check("zero rain → zero capture", area_m2 * runoff * 0.0 == 0.0)


## Deterministic sculpt op checks (berm / hill / swale / level perimeter).
func _test_sculpt_ops() -> void:
	var res := 17
	var extent := 160.0
	var base := PackedFloat32Array()
	base.resize(res * res)
	base.fill(100.0)
	var delta := PackedFloat32Array()
	delta.resize(res * res)
	delta.fill(0.0)
	var rmin := Vector2(-20.0, -20.0)
	var rmax := Vector2(20.0, 20.0)
	TerrainSculpt.apply_rect(delta, res, extent, rmin, rmax, "hill", 4.0, 2.0, base, 100.0)
	var c := TerrainSculpt.world_to_cell(0.0, 0.0, res, extent)
	var edge := TerrainSculpt.world_to_cell(18.0, 0.0, res, extent)
	_check("hill peaks at centre",
		delta[c.y * res + c.x] > delta[edge.y * res + edge.x] + 0.5,
		"mid=%f edge=%f" % [delta[c.y * res + c.x], delta[edge.y * res + edge.x]])

	delta.fill(0.0)
	TerrainSculpt.apply_rect(delta, res, extent, rmin, rmax, "berm", 3.0, 2.0, base, 100.0)
	var crest := TerrainSculpt.world_to_cell(0.0, 0.0, res, extent)
	var flank := TerrainSculpt.world_to_cell(0.0, 18.0, res, extent)
	_check("berm crest higher than flank",
		delta[crest.y * res + crest.x] > delta[flank.y * res + flank.x] + 0.3,
		"crest=%f flank=%f" % [delta[crest.y * res + crest.x], delta[flank.y * res + flank.x]])

	delta.fill(0.0)
	TerrainSculpt.apply_rect(delta, res, extent, rmin, rmax, "swale", 3.0, 2.0, base, 100.0)
	_check("swale digs below zero at crest",
		delta[crest.y * res + crest.x] < -0.5,
		"got %f" % delta[crest.y * res + crest.x])

	delta.fill(0.0)
	TerrainSculpt.apply_rect(delta, res, extent, rmin, rmax, "level", 5.0, 4.0, base, 100.0)
	# Level targets absolute height 5 m above centre (value - abs_h with abs_h=0).
	_check("level mid near target",
		_approx(delta[c.y * res + c.x], 5.0, 0.6),
		"got %f" % delta[c.y * res + c.x])


## Steepest-descent walk on synthetic surfaces — no scene/DEM needed, pure math.
func _test_trace_downhill() -> void:
	# 1. A uniform slope down toward +X: the walk should head almost due +X and
	# accumulate the exact drop the slope implies over the distance walked.
	var slope := 0.15  # 15% grade, height = 100 - 0.15*x
	var slope_h := func(x: float, _z: float) -> float:
		return 100.0 - slope * x
	var r1 := Watershed.trace_downhill(Vector2.ZERO, slope_h, 6.0, 4.0, 60)
	var pts1: PackedVector2Array = r1["points"]
	_check("slope: reaches target drop", bool(r1["reached_target"]))
	_check("slope: heads downhill (+X)", pts1[pts1.size() - 1].x > pts1[0].x,
		"end=%s" % str(pts1[pts1.size() - 1]))
	_check("slope: total drop matches target",
		_approx(float(r1["total_drop_m"]), 6.0, slope * 4.0 + 0.05),
		"got %f" % float(r1["total_drop_m"]))
	_check("slope: barely overshoots (re-samples each step, doesn't blow past)",
		float(r1["total_drop_m"]) < 6.0 + slope * 4.0 + 0.05)

	# 2. A radial bowl (paraboloid) centred at the origin: starting OFF-centre,
	# the walk must curve to point at the centre and STOP there (a true local
	# minimum) without ever reaching an artificially large target drop.
	var bowl_h := func(x: float, z: float) -> float:
		return 0.02 * (x * x + z * z)
	var start2 := Vector2(30.0, 0.0)
	var r2 := Watershed.trace_downhill(start2, bowl_h, 1000.0, 3.0, 40)
	var pts2: PackedVector2Array = r2["points"]
	_check("bowl: stops short of an unreachable target (found the local min)",
		not bool(r2["reached_target"]))
	_check("bowl: walk ends near the centre",
		pts2[pts2.size() - 1].length() < 6.0,
		"end=%s" % str(pts2[pts2.size() - 1]))
	_check("bowl: final elevation is the lowest point visited",
		float(r2["final_elev"]) <= bowl_h.call(start2.x, start2.y))
	_check("bowl: path has more than one point (actually walked)", pts2.size() > 1)

	# 3. Already at a local minimum (flat plane): a single-point path, zero drop,
	# not "reached" (target unreachable on flat ground) — no infinite loop.
	var flat_h := func(_x: float, _z: float) -> float:
		return 42.0
	var r3 := Watershed.trace_downhill(Vector2(5.0, 5.0), flat_h, 9.0, 4.0, 60)
	var pts3: PackedVector2Array = r3["points"]
	_check("flat: no movement on a flat plane", pts3.size() == 1)
	_check("flat: zero drop reported", _approx(float(r3["total_drop_m"]), 0.0, 1e-6))
	_check("flat: target not reached", not bool(r3["reached_target"]))
