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
	_test_sculpt_ops()
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
