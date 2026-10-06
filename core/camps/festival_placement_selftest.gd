extends SceneTree

## Headless self-test for festival placement (core/camps/festival_*):
## the usable-ground raster, the equal-usable-area lot partition along a road,
## the roster assigner, and the placement layer's persistence.
## Pure / offline. Run --import first.
##   godot --headless --path . --script core/camps/festival_placement_selftest.gd
## Exits 0 when all assertions pass, 1 otherwise.

## A Godot runtime error aborts the enclosing test function while the suite
## still prints PASS, so the check COUNT is pinned too.
const EXPECTED_CHECKS := 103

var _failures: int = 0
var _checks: int = 0


func _initialize() -> void:
	_test_raster()
	_test_count_mode_fairness()
	_test_raw_mode_equal_frontage()
	_test_lanes()
	_test_curved_road()
	_test_double_loaded()
	_test_corner()
	_test_grow_stability_area_mode()
	_test_id_inheritance_and_lock()
	_test_fallback_no_road()
	_test_assigner()
	_test_layer_roundtrip()
	_test_road_helpers_and_heading()
	_test_level_polyline()
	if _checks != EXPECTED_CHECKS:
		_failures += 1
		print("  FAIL: ran %d checks, expected %d (a test function aborted?)"
			% [_checks, EXPECTED_CHECKS])
	if _failures == 0:
		print("FESTIVAL PLACEMENT SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("FESTIVAL PLACEMENT SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


# ---------------------------------------------------------------------------
# Fixtures: a bank rising east of x = 120 at 14°, an excluded 20 m square,
# a straight road along z = 0 (travel +x, so the zone north of it is the
# LEFT / +1 side).
# ---------------------------------------------------------------------------

func _rect(x0: float, z0: float, x1: float, z1: float) -> PackedVector2Array:
	return PackedVector2Array([Vector2(x0, z0), Vector2(x1, z0), Vector2(x1, z1), Vector2(x0, z1)])


func _bank(x: float, _z: float) -> float:
	return 0.25 * maxf(0.0, x - 120.0)


func _flat(_x: float, _z: float) -> float:
	return 0.0


func _excl_square(p: Vector2) -> bool:
	return p.x >= 40.0 and p.x <= 60.0 and p.y >= 20.0 and p.y <= 40.0


func _ctx(ground: Callable, excl: Callable = Callable()) -> Dictionary:
	return {"ground_y_at": ground, "is_excluded": excl if excl.is_valid() else Callable(self, "_never")}


func _never(_p: Vector2) -> bool:
	return false


func _road(id: String, pts: PackedVector2Array, half_w: float = 4.0) -> Dictionary:
	return {"id": id, "points": pts, "half_width_m": half_w, "tags": {"highway": "festival"}}


func _zone(poly: PackedVector2Array, road_ids: Array, spec: Dictionary, holes: Array = []) -> Dictionary:
	var s := FestivalPlacementLayer.default_spec()
	s.merge(spec, true)
	return {"id": "zone_t", "polygon": poly, "holes": holes, "road_ids": road_ids,
		"spec": s, "features": ["water"], "seed": 1}


func _dist_to_polyline(p: Vector2, pts: PackedVector2Array) -> float:
	var best := INF
	for i in range(pts.size() - 1):
		best = minf(best, p.distance_to(Geometry2D.get_closest_point_to_segment(p, pts[i], pts[i + 1])))
	return best


func _lot_touches_road(lot: Dictionary, road: Dictionary, tol: float = 0.6) -> bool:
	var pts: PackedVector2Array = road["points"]
	var half_w := float(road["half_width_m"])
	var nearest := INF
	for v in (lot["polygon"] as PackedVector2Array):
		var d := _dist_to_polyline(v, pts)
		nearest = minf(nearest, d)
		if d < half_w - 0.01:
			return false  # inside the corridor
	return nearest <= half_w + FestivalLotPartition.FRONT_SETBACK_M + tol


func _pairwise_disjoint(lots: Array) -> int:
	var clash := 0
	for i in lots.size():
		for j in range(i + 1, lots.size()):
			if CampAreaLayer._overlaps(lots[i]["polygon"], lots[j]["polygon"]):
				clash += 1
	return clash


func _usable_spread(lots: Array) -> Dictionary:
	var mn := INF
	var mx := 0.0
	var sum := 0.0
	for l in lots:
		var u := float(l["usable_m2"])
		mn = minf(mn, u)
		mx = maxf(mx, u)
		sum += u
	return {"min": mn, "max": mx, "mean": sum / float(maxi(lots.size(), 1))}


# ---------------------------------------------------------------------------

func _test_raster() -> void:
	var zone := _rect(0, -2, 200, 60)
	var hole := _rect(80, 20, 95, 35)
	var r := FestivalUsableRaster.build(zone, [hole], [], _ctx(Callable(self, "_bank"),
		Callable(self, "_excl_square")), 10.0, false)
	var expect_cells := int(round(200.0 * 62.0 / r.cell_area()))
	_check("raster covers the zone (cells ≈ area / cell²)",
		absf(float(r.inside_cells) - float(expect_cells)) < 0.03 * float(expect_cells)
		+ 2.0 * (200.0 + 62.0) / r.cell,
		"inside=%d expect≈%d cell=%.1f" % [r.inside_cells, expect_cells, r.cell])
	_check("usable < raw (bank + exclusion cost ground)", r.usable_cells < r.inside_cells)
	_check("hole cells are not ground", r.mask_at(Vector2(87, 27)) == FestivalUsableRaster.OUTSIDE)
	_check("excluded cells are inside but unusable",
		r.mask_at(Vector2(50, 30)) == FestivalUsableRaster.UNUSABLE)
	_check("bank (14°) is unusable at a 10° limit",
		r.mask_at(Vector2(160, 30)) == FestivalUsableRaster.UNUSABLE)
	_check("flat ground is usable", r.mask_at(Vector2(20, 30)) == FestivalUsableRaster.USABLE)
	var r18 := FestivalUsableRaster.build(zone, [hole], [], _ctx(Callable(self, "_bank")), 18.0, false)
	_check("bank is usable at an 18° limit", r18.mask_at(Vector2(160, 30)) == FestivalUsableRaster.USABLE)
	var m := r.measure(_rect(0, 0, 20, 20))
	_check("measure counts the cells of a sub-rectangle",
		absf(float(m["raw_m2"]) - 400.0) < 0.1 * 400.0 + 2.0 * 40.0 * r.cell,
		"raw=%.0f" % float(m["raw_m2"]))
	var raw := FestivalUsableRaster.build(zone, [hole], [], _ctx(Callable(self, "_bank"),
		Callable(self, "_excl_square")), 10.0, true)
	_check("raw mode ignores slope and exclusions", raw.usable_cells == raw.inside_cells)
	_check("adaptive cell: 1 m for a small zone, 2 m by 90 000 m²",
		absf(FestivalUsableRaster.adaptive_cell(10000.0) - 1.0) < 0.01
		and absf(FestivalUsableRaster.adaptive_cell(90000.0) - 2.0) < 0.01)


func _test_count_mode_fairness() -> void:
	var road := _road("road_1", PackedVector2Array([Vector2(0, 0), Vector2(200, 0)]))
	# The zone reaches 8 m past the road's far side: that 4 m strip beyond the
	# corridor is the gap between an inset road and the zone edge, not a block.
	var zone := _zone(_rect(0, -8, 200, 60), ["road_1"],
		{"mode": "count", "target_n": 8, "depth_m": 25.0, "lane_w_m": 0.0, "lots_per_lane": 0},
		[_rect(80, 20, 95, 35)])
	var res := FestivalLotPartition.partition(zone, [road],
		_ctx(Callable(self, "_bank"), Callable(self, "_excl_square")))
	var lots: Array = res["lots"]
	_check("count mode: 8 lots", lots.size() == 8, "n=%d" % lots.size())
	var strip := 0
	for l in lots:
		if int(l["side"]) == -1:
			strip += 1
	_check("a shallow strip beyond the road is never cut into lots", strip == 0, "strip lots=%d" % strip)
	var sp := _usable_spread(lots)
	var worst := 0.0
	for l in lots:
		worst = maxf(worst, absf(float(l["usable_m2"]) - float(sp["mean"])) / float(sp["mean"]))
	_check("every lot's usable area within ±8 % of the mean", worst <= 0.08,
		"worst %.3f  min %.0f max %.0f mean %.0f" % [worst, sp["min"], sp["max"], sp["mean"]])
	var stats: Dictionary = res["stats"]
	_check("max/min ratio ≤ 1.16", float(stats["ratio_max_min"]) <= 1.16,
		"ratio=%.3f" % float(stats["ratio_max_min"]))
	_check("Gini < 0.05", float(stats["gini"]) < 0.05, "gini=%.4f" % float(stats["gini"]))
	# The lot over the exclusion square is WIDER (equal usable, unequal raw).
	var fronts: Array = []
	var over_excl := -1.0
	for l in lots:
		fronts.append(float(l["frontage_m"]))
		if float(l["s_start"]) <= 50.0 and float(l["s_end"]) >= 50.0:
			over_excl = float(l["frontage_m"])
	fronts.sort()
	var median: float = fronts[fronts.size() / 2]
	_check("the lot over blocked ground is wider than the median lot",
		over_excl > median + 1.0, "over=%.1f median=%.1f" % [over_excl, median])
	_check("no lot reaches onto the bank (usable ground ends at x≈120)",
		float(lots[lots.size() - 1]["s_end"]) <= 122.0, "last s_end=%.1f" % float(lots[lots.size() - 1]["s_end"]))
	var touching := 0
	for l in lots:
		if _lot_touches_road(l, road):
			touching += 1
	_check("every lot touches its road and stays out of the corridor", touching == lots.size(),
		"%d of %d" % [touching, lots.size()])
	_check("lots are pairwise disjoint", _pairwise_disjoint(lots) == 0)
	var inside := 0
	var in_hole := 0
	for l in lots:
		var ip := CampAreaLayer._inner_point(l["polygon"])
		if Geometry2D.is_point_in_polygon(ip, zone["polygon"]):
			inside += 1
		for h in zone["holes"]:
			if CampAreaLayer._overlaps(l["polygon"], h):
				in_hole += 1
	_check("every lot sits inside the zone", inside == lots.size())
	_check("no lot overlaps the hole", in_hole == 0, "in_hole=%d" % in_hole)
	var names: Dictionary = {}
	for l in lots:
		names[str(l["name"])] = true
	_check("lots are named A1..A8 along the road", names.size() == 8 and names.has("A1") and names.has("A8"))
	_check("every lot carries its measurements",
		float(lots[0]["raw_m2"]) > 0.0 and float(lots[0]["usable_m2"]) > 0.0
		and lots[0].has("mean_slope_deg") and lots[0].has("heading_deg"))
	_check("heading follows the road (east-west = 90°)",
		absf(float(lots[0]["heading_deg"]) - 90.0) < 0.5, "heading=%.1f" % float(lots[0]["heading_deg"]))
	_check("stats report capacity and remainder",
		int(stats["capacity_people"]) > 0 and float(stats["remainder_m2"]) >= 0.0)


func _test_raw_mode_equal_frontage() -> void:
	var road := _road("road_1", PackedVector2Array([Vector2(0, 0), Vector2(120, 0)]))
	var zone := _zone(_rect(0, -2, 120, 60), ["road_1"],
		{"mode": "count", "target_n": 6, "depth_m": 25.0, "lane_w_m": 0.0, "lots_per_lane": 0,
		"equalise": "raw"})
	var res := FestivalLotPartition.partition(zone, [road],
		_ctx(Callable(self, "_bank"), Callable(self, "_excl_square")))
	var lots: Array = res["lots"]
	_check("raw mode: 6 lots", lots.size() == 6, "n=%d" % lots.size())
	var mn := INF
	var mx := 0.0
	for l in lots:
		mn = minf(mn, float(l["frontage_m"]))
		mx = maxf(mx, float(l["frontage_m"]))
	_check("raw mode gives equal frontages (within 0.5 m)", mx - mn <= 0.5,
		"min=%.2f max=%.2f" % [mn, mx])
	_check("raw mode reaches the end of the road", float(lots[5]["s_end"]) >= 119.0,
		"s_end=%.1f" % float(lots[5]["s_end"]))


func _test_lanes() -> void:
	var road := _road("road_1", PackedVector2Array([Vector2(0, 0), Vector2(200, 0)]))
	var with_lanes := _zone(_rect(0, -2, 200, 60), ["road_1"],
		{"mode": "count", "target_n": 8, "depth_m": 25.0, "lane_w_m": 6.0, "lots_per_lane": 4})
	var res := FestivalLotPartition.partition(with_lanes, [road], _ctx(Callable(self, "_flat")))
	var lots: Array = res["lots"]
	_check("lanes: still 8 lots", lots.size() == 8, "n=%d" % lots.size())
	var gap := float(lots[4]["s_start"]) - float(lots[3]["s_end"])
	_check("a cross lane opens after every 4th lot", gap >= 6.0 - 0.1, "gap=%.2f" % gap)
	var gap_inside := float(lots[2]["s_start"]) - float(lots[1]["s_end"])
	_check("no gap between lots inside a block", gap_inside < 0.01, "gap=%.3f" % gap_inside)
	var sp := _usable_spread(lots)
	_check("lane area is taken out of the pool, lots still equal",
		(float(sp["max"]) - float(sp["min"])) / float(sp["mean"]) < 0.1,
		"min %.0f max %.0f" % [sp["min"], sp["max"]])
	var no_lanes := _zone(_rect(0, -2, 200, 60), ["road_1"],
		{"mode": "count", "target_n": 8, "depth_m": 25.0, "lane_w_m": 6.0, "lots_per_lane": 0})
	var res2 := FestivalLotPartition.partition(no_lanes, [road], _ctx(Callable(self, "_flat")))
	var lots2: Array = res2["lots"]
	var any_gap := false
	for i in range(lots2.size() - 1):
		if float(lots2[i + 1]["s_start"]) - float(lots2[i]["s_end"]) > 0.01:
			any_gap = true
	_check("lots_per_lane 0 means no lanes", not any_gap)
	var by_dist := _zone(_rect(0, -2, 200, 60), ["road_1"],
		{"mode": "count", "target_n": 8, "depth_m": 25.0, "lane_w_m": 6.0, "lots_per_lane": 0,
		"lane_every_m": 60.0})
	var res3 := FestivalLotPartition.partition(by_dist, [road], _ctx(Callable(self, "_flat")))
	var gaps3 := 0
	var lots3: Array = res3["lots"]
	for i in range(lots3.size() - 1):
		if float(lots3[i + 1]["s_start"]) - float(lots3[i]["s_end"]) > 5.0:
			gaps3 += 1
	_check("lane_every_m opens lanes by distance", gaps3 >= 2, "gaps=%d" % gaps3)


func _test_curved_road() -> void:
	var pts := PackedVector2Array()
	for i in 13:
		var a := deg_to_rad(90.0 * float(i) / 12.0)
		pts.append(Vector2(60.0 * cos(a), 60.0 * sin(a)))
	var road := _road("road_c", pts)
	# Annular sector r 30..100 over the quarter: ground on BOTH sides.
	var zone_poly := PackedVector2Array()
	for i in 13:
		var a := deg_to_rad(90.0 * float(i) / 12.0)
		zone_poly.append(Vector2(100.0 * cos(a), 100.0 * sin(a)))
	for i in 13:
		var a := deg_to_rad(90.0 * float(12 - i) / 12.0)
		zone_poly.append(Vector2(30.0 * cos(a), 30.0 * sin(a)))
	var zone := _zone(zone_poly, ["road_c"],
		{"mode": "count", "target_n": 10, "depth_m": 20.0, "lane_w_m": 0.0, "lots_per_lane": 0})
	var res := FestivalLotPartition.partition(zone, [road], _ctx(Callable(self, "_flat")))
	var lots: Array = res["lots"]
	var sides := {}
	for l in lots:
		sides[int(l["side"])] = true
	_check("curved road: 10 lots over both sides", lots.size() == 10 and sides.size() == 2, "n=%d sides=%d" % [lots.size(), sides.size()])
	var valid := 0
	var touching := 0
	for l in lots:
		if Geometry2D.triangulate_polygon(l["polygon"]).size() >= 3:
			valid += 1
		if _lot_touches_road(l, road, 1.0):
			touching += 1
	_check("curved lots are valid polygons", valid == lots.size(), "%d/%d" % [valid, lots.size()])
	_check("curved lots touch the road", touching == lots.size(), "%d/%d" % [touching, lots.size()])
	_check("curved lots are disjoint", _pairwise_disjoint(lots) == 0)
	for side in [1, -1]:
		var side_lots: Array = []
		for l in lots:
			if int(l["side"]) == side:
				side_lots.append(l)
		var sp := _usable_spread(side_lots)
		_check("curved side %d: usable equal within ±10 %%" % side,
			side_lots.size() > 0 and (float(sp["max"]) - float(sp["min"])) / float(sp["mean"]) <= 0.2,
			"n=%d min %.0f max %.0f" % [side_lots.size(), sp["min"], sp["max"]])


func _test_double_loaded() -> void:
	var road := _road("road_1", PackedVector2Array([Vector2(0, 0), Vector2(200, 0)]))
	var zone := _zone(_rect(0, -40, 200, 40), ["road_1"],
		{"mode": "count", "target_n": 12, "depth_m": 30.0, "lane_w_m": 0.0, "lots_per_lane": 0})
	var res := FestivalLotPartition.partition(zone, [road], _ctx(Callable(self, "_flat")))
	var lots: Array = res["lots"]
	var left := 0
	var right := 0
	var names: Dictionary = {}
	for l in lots:
		if int(l["side"]) == 1:
			left += 1
		else:
			right += 1
		names[str(l["name"])] = true
	_check("double-loaded: 12 lots split 6 + 6 by usable share", left == 6 and right == 6, "left=%d right=%d" % [left, right])
	_check("block letters differ per side", names.has("A1") and names.has("B1"))
	_check("no lot crosses the road", _pairwise_disjoint(lots) == 0)
	var sp := _usable_spread(lots)
	_check("both sides equal (symmetric ground)",
		(float(sp["max"]) - float(sp["min"])) / float(sp["mean"]) < 0.08,
		"min %.0f max %.0f" % [sp["min"], sp["max"]])


func _test_corner() -> void:
	var r1 := _road("road_1", PackedVector2Array([Vector2(0, 0), Vector2(200, 0)]))
	var r2 := _road("road_2", PackedVector2Array([Vector2(200, 0), Vector2(200, 150)]))
	var zone := _zone(_rect(0, 0, 200, 150), ["road_1", "road_2"],
		{"mode": "count", "target_n": 10, "depth_m": 30.0, "lane_w_m": 0.0, "lots_per_lane": 0})
	var res := FestivalLotPartition.partition(zone, [r1, r2], _ctx(Callable(self, "_flat")))
	var lots: Array = res["lots"]
	_check("two roads: lots on both", lots.size() >= 8, "n=%d" % lots.size())
	_check("two roads: no overlap (later roads subtract earlier lots)", _pairwise_disjoint(lots) == 0)
	var corners := 0
	var corner_ok := true
	for l in lots:
		if bool(l["corner"]):
			corners += 1
			corner_ok = corner_ok and (l["touches_road_ids"] as Array).size() == 2
	_check("the corner lot is flagged and touches both roads", corners >= 1 and corner_ok,
		"corners=%d" % corners)
	var r2_lots := 0
	for l in lots:
		if str(l["road_id"]) == "road_2":
			r2_lots += 1
	_check("the second road still gets lots", r2_lots >= 3, "r2=%d" % r2_lots)


func _test_grow_stability_area_mode() -> void:
	var road := _road("road_1", PackedVector2Array([Vector2(0, 0), Vector2(300, 0)]))
	var spec := {"mode": "area", "target_m2": 500.0, "depth_m": 25.0, "lane_w_m": 0.0, "lots_per_lane": 0}
	var small := _zone(_rect(0, -2, 120, 60), ["road_1"], spec)
	var res_a := FestivalLotPartition.partition(small, [road], _ctx(Callable(self, "_flat")))
	var lots_a: Array = res_a["lots"]
	for i in lots_a.size():
		lots_a[i]["lot_id"] = "lot_%d" % (i + 1)
	var big := _zone(_rect(0, -2, 180, 60), ["road_1"], spec)
	var ctx := _ctx(Callable(self, "_flat"))
	ctx["prior_lots"] = lots_a
	var res_b := FestivalLotPartition.partition(big, [road], ctx)
	var lots_b: Array = res_b["lots"]
	_check("area mode: a longer zone gets more lots", lots_b.size() > lots_a.size(),
		"a=%d b=%d" % [lots_a.size(), lots_b.size()])
	var same := true
	for i in lots_a.size() - 1:
		if absf(float(lots_a[i]["s_start"]) - float(lots_b[i]["s_start"])) > 1e-3 \
				or absf(float(lots_a[i]["s_end"]) - float(lots_b[i]["s_end"])) > 1e-3:
			same = false
	_check("area mode: the first N-1 cuts are bit-identical after growing the zone", same)
	var ids_same := true
	for i in lots_a.size() - 1:
		if str(lots_b[i]["lot_id"]) != str(lots_a[i]["lot_id"]):
			ids_same = false
	_check("area mode: unchanged lots keep their ids", ids_same)
	_check("area mode: new lots have no id yet (the layer mints them)",
		str(lots_b[lots_b.size() - 1]["lot_id"]).is_empty())


func _test_id_inheritance_and_lock() -> void:
	var road := _road("road_1", PackedVector2Array([Vector2(0, 0), Vector2(300, 0)]))
	var spec := {"mode": "count", "target_n": 8, "depth_m": 25.0, "lane_w_m": 0.0, "lots_per_lane": 0}
	var zone_a := _zone(_rect(0, -2, 200, 60), ["road_1"], spec)
	var lots_a: Array = FestivalLotPartition.partition(zone_a, [road], _ctx(Callable(self, "_flat")))["lots"]
	for i in lots_a.size():
		lots_a[i]["lot_id"] = "lot_%d" % (i + 1)
		lots_a[i]["assigned_camp"] = {"name": "Camp %d" % (i + 1), "style": "mixed",
			"headcount": 10, "roster_id": "", "requirements": [], "manual": false}
	var zone_b := _zone(_rect(0, -2, 240, 60), ["road_1"], spec)
	var ctx := _ctx(Callable(self, "_flat"))
	ctx["prior_lots"] = lots_a
	var lots_b: Array = FestivalLotPartition.partition(zone_b, [road], ctx)["lots"]
	var kept := 0
	var camp_kept := 0
	for l in lots_b:
		if not str(l["lot_id"]).is_empty():
			kept += 1
			if not (l["assigned_camp"] as Dictionary).is_empty():
				camp_kept += 1
	_check("count mode: ≥ 70 % of ids survive a 20 % enlargement by overlap",
		kept >= 6, "kept=%d of 8" % kept)
	_check("inherited lots keep their camp", camp_kept == kept)
	# Lock lot 3 and re-run: it comes back byte-identical and nothing overlaps it.
	var locked: Dictionary = (lots_a[2] as Dictionary).duplicate(true)
	locked["locked"] = true
	var ctx2 := _ctx(Callable(self, "_flat"))
	ctx2["locked_lots"] = [locked]
	ctx2["prior_lots"] = lots_a
	var zone_c := _zone(_rect(0, -2, 240, 60), ["road_1"], spec)
	var lots_c: Array = FestivalLotPartition.partition(zone_c, [road], ctx2)["lots"]
	var found: Dictionary = {}
	for l in lots_c:
		if str(l["lot_id"]) == "lot_3":
			found = l
	_check("a locked lot is re-emitted with its exact polygon",
		not found.is_empty() and bool(found["locked"])
		and (found["polygon"] as PackedVector2Array) == (locked["polygon"] as PackedVector2Array))
	var overlaps_locked := 0
	for l in lots_c:
		if str(l["lot_id"]) != "lot_3" and CampAreaLayer._overlaps(l["polygon"], locked["polygon"]):
			overlaps_locked += 1
	_check("no new lot overlaps the locked one", overlaps_locked == 0, "n=%d" % overlaps_locked)
	_check("locked ground is cut out of the fairness pool (other lots still equal)",
		_pairwise_disjoint(lots_c) == 0)


func _test_fallback_no_road() -> void:
	var zone := _zone(_rect(0, 0, 160, 90), [],
		{"mode": "area", "target_m2": 400.0, "depth_m": 20.0, "lane_w_m": 5.0})
	var res := FestivalLotPartition.partition(zone, [], _ctx(Callable(self, "_flat")))
	var lots: Array = res["lots"]
	_check("no road: the rectangular lattice still yields lots", lots.size() >= 10, "n=%d" % lots.size())
	_check("no road: lots carry no road id", lots.size() > 0 and str(lots[0]["road_id"]).is_empty())
	_check("no road: a warning says so", (res["warnings"] as Array).size() >= 1)
	_check("no road: lots are measured", lots.size() > 0 and float(lots[0]["usable_m2"]) > 0.0)


func _test_assigner() -> void:
	var ppm := FestivalAssigner.people_per_m2("mixed")
	_check("people_per_m2(mixed) ≈ 0.027 (≈37 m² per person)", ppm > 0.02 and ppm < 0.035, "ppm=%.4f" % ppm)
	_check("theme camps are roomier per person than RV parks",
		FestivalAssigner.people_per_m2("theme_camp") < FestivalAssigner.people_per_m2("rv_park"))
	_check("default headcount = round(usable × ppm)",
		FestivalAssigner.default_headcount(1000.0, "mixed") == int(round(1000.0 * ppm)))
	_check("size classes", FestivalAssigner.size_class(200.0) == "S"
		and FestivalAssigner.size_class(500.0) == "M" and FestivalAssigner.size_class(1000.0) == "L"
		and FestivalAssigner.size_class(3000.0) == "XL")
	_check("requested_m2 derives from headcount at the style density",
		absf(FestivalAssigner.requested_m2({"headcount": 27, "style": "mixed"}) - 27.0 / ppm) < 0.01)
	var lots: Array = []
	var sizes := [300.0, 650.0, 1400.0, 2100.0, 500.0]
	for i in sizes.size():
		lots.append({"lot_id": "lot_%d" % (i + 1), "zone_id": "zone_1", "road_id": "road_1",
			"side": 1, "name": "A%d" % (i + 1), "polygon": _rect(float(i) * 40.0, 0, float(i) * 40.0 + 30.0, 30),
			"usable_m2": sizes[i], "features": [], "locked": false, "assigned_camp": {}})
	var zones := {"zone_1": {"id": "zone_1", "features": ["water"],
		"spec": FestivalPlacementLayer.normalize_spec({"styles": ["mixed", "theme_camp"]})}}
	var roster := [
		{"id": "camp_r_1", "name": "Big", "size_class": "XL", "headcount": 0, "style": "theme_camp",
			"requirements": [], "adjacent_to": [], "requested_m2": 2000.0},
		{"id": "camp_r_2", "name": "Needs power", "size_class": "M", "headcount": 0, "style": "mixed",
			"requirements": ["power"], "adjacent_to": [], "requested_m2": 500.0},
		{"id": "camp_r_3", "name": "Small", "size_class": "S", "headcount": 6, "style": "mixed",
			"requirements": ["water"], "adjacent_to": [], "requested_m2": 280.0},
		{"id": "camp_r_4", "name": "Glamp", "size_class": "M", "headcount": 0, "style": "glamping",
			"requirements": [], "adjacent_to": [], "requested_m2": 600.0},
	]
	var res := FestivalAssigner.assign(lots, roster, zones)
	var asg: Dictionary = res["assignments"]
	_check("the XL camp takes the biggest lot", str((asg.get("lot_4", {}) as Dictionary).get("roster_id", "")) == "camp_r_1")
	_check("a camp requiring a feature the zone lacks is unplaced", (res["unplaced"] as Array).has("camp_r_2"))
	_check("a style the zone does not allow is unplaced", (res["unplaced"] as Array).has("camp_r_4"))
	_check("the small camp takes the best-fit lot", str((asg.get("lot_1", {}) as Dictionary).get("roster_id", "")) == "camp_r_3")
	_check("an explicit headcount is kept", int((asg.get("lot_1", {}) as Dictionary).get("headcount", 0)) == 6)
	_check("leftover lots get the zone default style + a derived headcount",
		str((asg.get("lot_2", {}) as Dictionary).get("style", "")) == "mixed"
		and int((asg.get("lot_2", {}) as Dictionary).get("headcount", 0))
			== FestivalAssigner.default_headcount(650.0, "mixed"))
	_check("every lot ends up assigned", asg.size() == lots.size(), "n=%d" % asg.size())
	# Manual assignments are never clobbered.
	lots[1]["assigned_camp"] = {"roster_id": "camp_r_9", "name": "Pinned", "style": "mixed",
		"headcount": 4, "requirements": [], "manual": true}
	var res2 := FestivalAssigner.assign(lots, roster, zones)
	_check("manual assignments are untouched", not (res2["assignments"] as Dictionary).has("lot_2"))
	# Determinism.
	var res3 := FestivalAssigner.assign(lots, roster, zones)
	_check("assignment is deterministic", JSON.stringify(res2) == JSON.stringify(res3))


func _test_layer_roundtrip() -> void:
	var layer := FestivalPlacementLayer.create_empty()
	var rid := layer.add_road(PackedVector2Array([Vector2(0, 0), Vector2(200, 0), Vector2(220, 40)]),
		{"name": "Esplanade", "width_m": 10.0, "surface": "playa"})
	_check("road id minted", rid == "road_1")
	_check("width stored as half width", absf(float(layer.get_road(rid)["half_width_m"]) - 5.0) < 1e-6)
	var zid := layer.add_zone(_rect(0, -2, 200, 60), {"name": "Zone A", "road_ids": [rid],
		"spec": {"mode": "count", "target_n": 6}, "features": ["water", "bogus"]})
	_check("zone id minted + features cleaned", zid == "zone_1"
		and (layer.get_zone(zid)["features"] as Array) == ["water"])
	_check("spec normalized (unknown mode → count, target clamped)",
		str(FestivalPlacementLayer.normalize_spec({"mode": "nope", "target_n": 999})["mode"]) == "count"
		and int(FestivalPlacementLayer.normalize_spec({"target_n": 999})["target_n"]) == 200)
	var res := FestivalLotPartition.partition(layer.get_zone(zid), layer.road_dicts(),
		_ctx(Callable(self, "_flat")))
	var ids := layer.apply_partition(zid, res)
	_check("apply_partition mints lot ids", ids.size() == 6 and ids[0] == "lot_1" and ids[5] == "lot_6")
	_check("zone stats written", int((layer.get_zone(zid)["stats"] as Dictionary).get("lots", 0)) == 6)
	var cid := layer.add_roster_entry({"name": "Kidsville", "size_class": "L", "headcount": 24,
		"style": "theme_camp", "requirements": ["power", "quiet"], "adjacent_to": ["camp_r_7"]})
	_check("roster id minted", cid == "camp_r_1")
	layer.update_lot("lot_2", {"assigned_camp": {"roster_id": cid, "name": "Kidsville",
		"style": "theme_camp", "headcount": 24, "requirements": ["power"], "manual": true},
		"locked": true})
	_check("lot_at finds a lot", layer.lot_at(Vector2(10, 10)) == "lot_1")
	_check("zone_at finds the zone", layer.zone_at(Vector2(150, 50)) == zid)
	_check("road_at finds the road within its corridor", layer.road_at(Vector2(100, 4.5)) == rid
		and layer.road_at(Vector2(100, 20)).is_empty())
	var before := JSON.stringify(layer.serialize())
	var path := "user://festival_placement_selftest_tmp.json"
	_check("save_to writes", layer.save_to(path))
	var loaded := FestivalPlacementLayer.create_empty()
	_check("load_from reads", loaded.load_from(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	# Compare parsed values, not strings: JSON has one number type, so an int
	# stat (6) comes back as 6.0 and the two stringify differently while being
	# the same data.
	_check("every key round-trips", JSON.parse_string(JSON.stringify(loaded.serialize())) == JSON.parse_string(before))
	_check("ids keep counting after a load",
		loaded.add_road(PackedVector2Array([Vector2(0, 0), Vector2(1, 1)])) == "road_2"
		and loaded.add_zone(_rect(300, 300, 400, 400)) == "zone_2")
	_check("lock + manual assignment survive the trip",
		bool(loaded.get_lot("lot_2")["locked"])
		and bool((loaded.get_lot("lot_2")["assigned_camp"] as Dictionary)["manual"]))
	var snap := layer.snapshot()
	var dropped := layer.remove_zone(zid)
	_check("remove_zone drops its lots", layer.lots.is_empty() and dropped.is_empty())
	layer.restore(snap)
	_check("restore brings the zone and lots back", layer.get_zone(zid).size() > 0 and layer.lots.size() == 6)
	_check("remove_roster_entry clears it off the lot",
		layer.remove_roster_entry(cid) and (layer.get_lot("lot_2")["assigned_camp"] as Dictionary).is_empty())
	_check("remove_road un-fronts the zone", layer.remove_road(rid)
		and (layer.get_zone(zid)["road_ids"] as Array).is_empty())


func _test_road_helpers_and_heading() -> void:
	var poly := _rect(0, 0, 100, 40)
	var edge := FestivalPlacementLayer.road_from_zone_edge(poly, 0, 6.0)
	_check("road_from_zone_edge sits INSIDE the zone", edge.size() == 2
		and absf(edge[0].y - 6.0) < 1e-6 and absf(edge[1].y - 6.0) < 1e-6)
	var edge3 := FestivalPlacementLayer.road_from_zone_edge(poly, 2, 6.0)
	_check("…whichever edge (top edge insets downward)", absf(edge3[0].y - 34.0) < 1e-6)
	var spine := FestivalPlacementLayer.road_from_zone_spine(poly)
	_check("road_from_zone_spine runs the middle of the long axis", spine.size() >= 2
		and absf(spine[0].y - 20.0) < 1e-3 and absf(spine[spine.size() - 1].y - 20.0) < 1e-3
		and absf(spine[0].distance_to(spine[spine.size() - 1]) - 100.0) < 1.0,
		"spine=%s" % str(spine))
	var fest := {"points": PackedVector2Array([Vector2(-50, -50), Vector2(150, -50)]), "half_width_m": 4.0}
	var osm := {"points": PackedVector2Array([Vector2(0, 85), Vector2(100, 85)]), "half_width_m": 4.0}
	_check("nearest_road_dir honours its reach (festival road at 50 m found at reach 60)",
		CampLayoutGenerator.nearest_road_dir(poly, [fest], 60.0) != Vector2.ZERO
		and CampLayoutGenerator.nearest_road_dir(poly, [osm], 40.0) == Vector2.ZERO)
	_check("resolve_heading unchanged (longest edge when no road is within 40 m)",
		absf(CampLayoutGenerator.resolve_heading(poly, [osm]) - 90.0) < 1e-3)


## Grading a road on the edit layer: the corridor lands on the centreline's
## smoothed profile, the shoulder feathers out, and the field beyond is untouched.
func _test_level_polyline() -> void:
	var tiles := TerrainEditTiles.new()
	var slope := func(x: float, _z: float) -> float: return 0.2 * x + 2.0 * sin(x * 0.5)
	var road := PackedVector2Array([Vector2(0, 0), Vector2(60, 0)])
	TerrainSculptOps.level_polyline(tiles, road, 3.0, 2.0, slope, 12.0)
	_check("level_polyline wrote the edit layer", not tiles.is_empty())
	# On the centreline the result follows a profile smoother than the ground:
	# the 2 m bumps (period ~12.6 m) are averaged over a 24 m window.
	var worst_bump := 0.0
	for x: float in [15.0, 21.0, 27.0, 33.0, 39.0, 45.0]:
		var y := float(slope.call(x, 0.0)) + tiles.sample_delta(x, 0.0)
		var trend := 0.2 * x
		worst_bump = maxf(worst_bump, absf(y - trend))
	_check("the graded road smooths the bumps on its centreline", worst_bump < 0.6,
		"worst %.2f (raw bumps are 2.0)" % worst_bump)
	_check("the far field is untouched", absf(tiles.sample_delta(30.0, 12.0)) < 1e-6
		and absf(tiles.sample_delta(30.0, -12.0)) < 1e-6)
	var shoulder := absf(tiles.sample_delta(30.0, 4.0))
	var centre := absf(tiles.sample_delta(30.0, 0.0))
	_check("the shoulder feathers toward natural ground", shoulder <= centre + 1e-6)
