extends SceneTree

## Offline checks for structure earthworks (core/earthworks/): the spec,
## placement into the world, the solver's berms / cuts / ramps / interior
## sink, overrides against sculpted ground, the hole queries, the mask and
## the edge collar. Run:
##   Godot --headless --path . --script core/earthworks/earthworks_selftest.gd

const EXPECTED_CHECKS := 77
const CELL := 1.5

var _pass := 0
var _fail := 0


func _initialize() -> void:
	_test_resolve()
	_test_placement()
	_test_hole_sink()
	_test_berms()
	_test_cuts_and_ramps()
	_test_override_on_sculpt()
	_test_move_and_combine()
	_test_hole_queries()
	_test_mask_and_collar()
	_test_basement()
	_test_lights_and_door()
	_test_earth_temperature()
	var total := _pass + _fail
	if total != EXPECTED_CHECKS:
		_fail += 1
		print("FAIL check count %d != EXPECTED_CHECKS %d" % [total, EXPECTED_CHECKS])
	print("earthworks_selftest: %d passed, %d failed" % [_pass, _fail])
	print("PASS" if _fail == 0 else "FAILED")
	quit(1 if _fail > 0 else 0)


func _ok(cond: bool, what: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		print("FAIL ", what)


func _near(a: float, b: float, tol: float, what: String) -> void:
	_ok(absf(a - b) <= tol, "%s (%.4f vs %.4f)" % [what, a, b])


func _flat(h: float) -> Callable:
	return func(_x: float, _z: float) -> float: return h


func _rec(spec: Dictionary, x := 0.0, z := 0.0, yaw := 0.0) -> Dictionary:
	return {"id": "p1", "x": x, "z": z, "yaw": yaw, StructureEarthworks.KEY: spec}


func _delta(deltas: Dictionary, x: float, z: float) -> float:
	return float(deltas.get(Vector2i(roundi(x / CELL), roundi(z / CELL)), 0.0))


func _test_resolve() -> void:
	var s := StructureEarthworks.resolve({"rect": [5, 5, -5, -5], "roof_y": -9, "berm": {"-z": {"h": 2}}})
	_ok((s["rect"] as Array)[0] == -5.0 and (s["rect"] as Array)[2] == 5.0, "rect sorted")
	_ok(float(s["roof_y"]) > float(s["floor_y"]), "roof kept above floor")
	_ok((s["berm"] as Dictionary).has("-z"), "berm side kept")
	_near(float(s["berm"]["-z"]["run"]), StructureEarthworks.DEFAULT_RUN_M, 1e-6, "berm run default")
	var s2 := StructureEarthworks.resolve({"berm": {"+z": {"h": 0.0}}, "future_key": 7})
	_ok(not (s2["berm"] as Dictionary).has("+z"), "zero berm dropped")
	_ok(int(s2.get("future_key", 0)) == 7, "unknown key survives")
	_ok(StructureEarthworks.is_on(_rec({})) and not StructureEarthworks.is_on({}), "is_on")


func _test_placement() -> void:
	var pl := StructureEarthworks.placement(_rec({"rect": [-2, -1, 2, 1], "sink_m": 0.5}, 10.0, 20.0, 90.0), 3.0)
	_near(float(pl["y0"]), 2.5, 1e-5, "y0 = grade - sink")
	var foot: PackedVector2Array = pl["foot"]
	# yaw 90 turns local +x toward world -z.
	var minz := INF
	var maxz := -INF
	for p in foot:
		minz = minf(minz, p.y)
		maxz = maxf(maxz, p.y)
	_near(maxz - minz, 4.0, 1e-4, "yaw 90 swaps the rect's long side onto z")
	_near(float(pl["hole"]["floor"]), 2.5 - 1.0, 1e-5, "hole floor at y0 + floor_y")


func _test_hole_sink() -> void:
	var spec := {"rect": [-6, -6, 6, 6], "floor_y": -1.0}
	var pl := StructureEarthworks.placement(_rec(spec), 0.0)
	var d := StructureEarthworks.solve([pl], _flat(0.0), CELL)
	_near(_delta(d, 0.0, 0.0), -1.0 - StructureEarthworks.INTERIOR_SINK_M, 1e-4, "interior sunk below the floor")
	_near(_delta(d, 5.25, 0.0), 0.0, 1e-4, "sample a cell inside the wall stays at the ground")
	_near(_delta(d, 9.0, 0.0), 0.0, 1e-4, "outside untouched without berms")


func _test_berms() -> void:
	var spec := {"rect": [-4, -3, 4, 3], "hole": false,
		"berm": {"-z": {"h": 2.0, "run": 2.0, "crest": 0.6}, "+x": {"h": -1.0, "run": 1.0, "crest": 0.0}},
		"roof_y": 2.7}
	var pl := StructureEarthworks.placement(_rec(spec), 0.0)
	var d := StructureEarthworks.solve([pl], _flat(0.0), CELL)
	# Back side: z < -3. A sample 0.0 m from origin x, z = -3 - 0.0..
	_near(_delta(d, 0.0, -3.0), 2.0, 1e-4, "berm top at the wall")
	_near(_delta(d, 0.0, -6.0), 2.0 - (3.0 - 0.6) / 2.0, 1e-4, "berm falls at its run")
	_near(_delta(d, 0.0, -9.0), 0.0, 1e-4, "berm meets grade")
	_near(_delta(d, 0.0, 0.0), 0.0, 1e-4, "no berm inside the footprint")
	_near(_delta(d, 4.5, 0.0), 2.7 - 0.5, 1e-4, "to-roof berm reaches the roof less its fall")
	_ok(_delta(d, 0.0, 6.0) == 0.0, "front side left open")
	_ok(_delta(d, 6.0, -5.0) > 0.0, "corner wraps between two bermed sides")


func _test_cuts_and_ramps() -> void:
	var spec := {"rect": [-4, -3, 4, 3], "hole": false, "floor_y": -1.2}
	spec["cuts"] = [StructureEarthworks.daylight_cut(spec, "+z", 3.0, 2.0)]
	spec["ramps"] = [{"a": [6.0, 9.0], "b": [6.0, 4.5], "ya": 0.0, "yb": -1.2, "w": 1.5, "run": 1.0}]
	var pl := StructureEarthworks.placement(_rec(spec), 0.0)
	var d := StructureEarthworks.solve([pl], _flat(0.0), CELL)
	_near(_delta(d, 0.0, 4.5), -1.2, 1e-4, "daylight cut floor")
	_near(_delta(d, 0.0, 7.5), -1.2 + 1.5 / 2.0, 1e-4, "cut side rises at its run")
	_near(_delta(d, 0.0, 12.0), 0.0, 1e-4, "cut ends at grade")
	_near(_delta(d, 6.0, 9.0), 0.0, 0.02, "ramp starts at grade")
	_near(_delta(d, 6.0, 4.5), -1.2, 0.02, "ramp ends at the floor")
	_ok(_delta(d, 6.0, 6.0) < -0.3 and _delta(d, 6.0, 6.0) > -1.0, "ramp in between")


func _test_override_on_sculpt() -> void:
	# The player raised the whole area 0.5 m: grade follows, so a berm 2 m
	# over GRADE needs a 2 m delta, and a floor 1 m under y0 is still exact.
	var spec := {"rect": [-6, -6, 6, 6], "floor_y": -1.0, "berm": {"-z": {"h": 2.0}}}
	var pl := StructureEarthworks.placement(_rec(spec), 0.5)
	var d := StructureEarthworks.solve([pl], _flat(0.5), CELL)
	_near(_delta(d, 0.0, -6.0), 2.0, 1e-4, "berm measured from the sculpted grade")
	_near(0.5 + _delta(d, 0.0, 0.0), 0.5 - 1.0 - StructureEarthworks.INTERIOR_SINK_M, 1e-4,
		"interior lands at an absolute height on sculpted ground")
	# Uneven ground: a slope under a level berm top still lands level.
	var slope := func(_x: float, z: float) -> float: return z * 0.1
	var d2 := StructureEarthworks.solve([StructureEarthworks.placement(_rec(spec), 0.0)], slope, CELL)
	_near(-6.0 * 0.1 + _delta(d2, 0.0, -6.0), 2.0, 1e-4, "berm top level on a slope")


func _test_move_and_combine() -> void:
	var spec := {"rect": [-3, -3, 3, 3], "berm": {"-z": {"h": 1.5}}}
	var a := StructureEarthworks.solve([StructureEarthworks.placement(_rec(spec), 0.0)], _flat(0.0), CELL)
	var b := StructureEarthworks.solve([StructureEarthworks.placement(_rec(spec, 15.0, 0.0), 0.0)], _flat(0.0), CELL)
	_ok(a.size() == b.size(), "moving keeps the sample count")
	_near(_delta(a, 0.0, -4.5), _delta(b, 15.0, -4.5), 1e-5, "moving carries the berm")
	_near(_delta(b, 0.0, -4.5), 0.0, 1e-5, "old spot restored")
	var c := StructureEarthworks.solve([], _flat(0.0), CELL)
	_ok(c.is_empty(), "no structures, no deltas")
	# A cut from a neighbour beats this one's berm where they overlap.
	var nb := {"rect": [-2, -12, 2, -8], "hole": false, "cuts": [{"poly": [[-2, -8], [2, -8], [2, -5], [-2, -5]], "floor_y": -1.0}]}
	var both := StructureEarthworks.solve([StructureEarthworks.placement(_rec(spec), 0.0),
		StructureEarthworks.placement(_rec(nb), 0.0)], _flat(0.0), CELL)
	_near(_delta(both, 0.0, -6.0), -1.0, 1e-4, "cut wins over a neighbour's berm")
	var r := StructureEarthworks.reach_rect(StructureEarthworks.placement(_rec(spec), 0.0))
	_ok(r.has_point(Vector2(0, -6)) and not r.has_point(Vector2(0, -40)), "reach rect bounds the berm")


func _test_hole_queries() -> void:
	var p1 := StructureEarthworks.placement(_rec({"rect": [-4, -4, 4, 4], "floor_y": -2.0, "roof_y": 1.0}), 10.0)
	var p2 := StructureEarthworks.placement(_rec({"rect": [-1, -1, 1, 1], "hole": false}, 30.0), 0.0)
	var holes := StructureEarthworks.holes_of([p1, p2])
	_ok(holes.size() == 1, "only openings are holes")
	StructureEarthworks.index_holes(holes)
	_ok((holes[0]["rect"] as Rect2).size.x > 7.9, "hole rect indexed")
	var h := StructureEarthworks.hole_at(holes, Vector2(1, 1))
	_near(float(h.get("floor", -99)), 8.0, 1e-5, "ground inside reads the floor")
	_near(float(h.get("roof", -99)), 11.0, 1e-5, "water inside reads the roof")
	_ok(StructureEarthworks.hole_at(holes, Vector2(6, 0)).is_empty(), "outside is no hole")
	var s := WaterGroundSampler.from_fn(_flat(10.0))
	s.roofs = holes
	_near(s.surface_at(0.0, 0.0), 11.0, 1e-5, "water sampler routes over the roof")
	_near(s.surface_at(9.0, 0.0), 10.0, 1e-5, "water sampler elsewhere unchanged")
	_near(StructureEarthworks.poly_edge_dist(Vector2(0, 0), holes[0]["poly"]), 4.0, 1e-5, "edge distance")


func _test_mask_and_collar() -> void:
	var p1 := StructureEarthworks.placement(_rec({"rect": [-4, -2, 4, 2]}, 0.0, 0.0, 30.0), 0.0)
	var holes := StructureEarthworks.holes_of([p1])
	var m := TerrainHoleMask.build(holes)
	_ok(int(m["count"]) == 1 and m["tex"] is Texture2DArray, "mask has a layer per hole")
	var rect: Vector4 = (m["rects"] as PackedVector4Array)[0]
	_ok(rect.x < -4.0 and rect.z > 8.0, "mask rect covers the footprint plus padding")
	var many: Array = []
	for i in 20:
		many.append({"poly": PackedVector2Array([Vector2(i * 10, 0), Vector2(i * 10 + 2, 0), Vector2(i * 10 + 2, 2)])})
	_ok(int(TerrainHoleMask.build(many)["count"]) == TerrainHoleMask.MAX_HOLES, "mask capped")
	var poly: PackedVector2Array = holes[0]["poly"]
	var faces := EarthworksRuntime.collar_faces(poly, _flat(1.25))
	_ok(faces.size() > 0 and faces.size() % 3 == 0, "collar is triangles")
	var all_out := true
	var all_h := true
	for f in faces:
		if Geometry2D.is_point_in_polygon(Vector2(f.x, f.z), poly) \
				and StructureEarthworks.poly_edge_dist(Vector2(f.x, f.z), poly) > 0.01:
			all_out = false
		if absf(f.y - 1.27) > 1e-4:
			all_h = false
	_ok(all_out, "collar stays outside the wall line")
	_ok(all_h, "collar follows the drawn ground")
	var o := EarthworksRuntime.outward(poly, poly[0], poly[1])
	var mid := (poly[0] + poly[1]) * 0.5
	_ok(not Geometry2D.is_point_in_polygon(mid + o * 0.2, poly), "outward normal points out")


func _test_basement() -> void:
	var spec := {"width_m": 8.0, "depth_m": 6.0, "height_m": 3.0,
		"basement": {"depth_m": 2.4, "entry": "walkout", "edge": 0, "door_at": 0.25}}
	var poly := BuildingFeatures.footprint_of(spec)
	_ok(BasementBuilder.side_of_edge(poly, 0) == "-z", "rect edge 0 faces -z")
	_ok(BasementBuilder.side_of_edge(poly, 1) == "+x", "rect edge 1 faces +x")
	var ew := BasementBuilder.earthworks_for_building(spec)
	_near(float(ew["floor_y"]), -2.4, 1e-5, "basement floor depth")
	_ok((ew["cuts"] as Array).size() == 1 and (ew["ramps"] as Array).size() == 1, "walkout cut and ramp")
	_near(float(ew["ramps"][0]["b"][0]), -2.0, 1e-4, "ramp comes in at the door")
	var rec := {"model_id": BuildingFeatures.MODEL_ID, "x": 0.0, "z": 0.0, "building_spec": spec}
	_ok(StructureEarthworks.is_on(rec), "a building with a basement asks for earthworks")
	_ok(not StructureEarthworks.is_on({"model_id": BuildingFeatures.MODEL_ID, "building_spec": {"width_m": 8.0}}),
		"no basement, no earthworks")
	var node := BuildingBuilder.build_node(spec)
	_ok(node.get_node_or_null("Basement/FoundationWalls") != null, "the house draws its basement")
	node.free()


func _test_lights_and_door() -> void:
	# A 10 x 6 room sunk 2.4 m: lights under its ceiling, inside it, at most LIGHT_MAX.
	var sm := {"rect": [-5.0, -3.0, 5.0, 3.0], "hole": true, "floor_y": -2.4, "roof_y": 0.4,
		"daylight": "+z", "cut_w": 3.0, "ramp_len": 4.0, "ramp_at": 1.5}
	var spec := StructureEarthworks.from_simple(sm)
	_ok(bool(spec["lights"]), "lights on by default")
	var pl := StructureEarthworks.placement(_rec(spec, 100.0, 50.0, 0.0), 10.0)
	var pts := EarthworksRuntime.light_points(pl["hole"])
	_ok(pts.size() >= 2 and pts.size() <= EarthworksRuntime.LIGHT_MAX, "a few lights (%d)" % pts.size())
	var inside := true
	for q in pts:
		if not Geometry2D.is_point_in_polygon(Vector2(q.x, q.z), pl["hole"]["poly"]):
			inside = false
	_ok(inside, "every light inside the opening")
	_ok(pts.size() > 0 and pts[0].y > 10.0 - 2.4 and pts[0].y < 10.0 + 0.4, "lights hang between floor and roof")
	var shallow := StructureEarthworks.placement(_rec(StructureEarthworks.from_simple(
		{"rect": [-5.0, -3.0, 5.0, 3.0], "floor_y": -0.3, "roof_y": 2.5}), 0.0, 0.0, 0.0), 10.0)
	_ok(EarthworksRuntime.light_points(shallow["hole"]).is_empty(), "no lights where daylight reaches the floor")
	var off := StructureEarthworks.placement(_rec(StructureEarthworks.from_simple(
		{"rect": [-5.0, -3.0, 5.0, 3.0], "floor_y": -2.4, "lights": false}), 0.0, 0.0, 0.0), 10.0)
	_ok(not bool(off["hole"]["lights"]), "lights can be turned off")
	_ok(not bool(StructureEarthworks.simple_of(off["spec"]).get("lights", true)), "and the simple form keeps it")
	# The door: on the daylight (+z) wall at ramp_at, in the world.
	var dp: Variant = EarthworksRuntime.door_point(pl)
	_ok(dp is Vector2, "a daylight side has a door")
	_near((dp as Vector2).x, 101.5, 1e-4, "door at ramp_at along the side")
	_near((dp as Vector2).y, 53.0, 1e-4, "door on the front wall line")
	var turned := StructureEarthworks.placement(_rec(spec, 0.0, 0.0, 90.0), 10.0)
	var dp2: Variant = EarthworksRuntime.door_point(turned)
	# Yaw 90 turns the front (+z) wall to face +x: local (1.5, 3) lands at (3, -1.5).
	_ok(dp2 is Vector2 and (dp2 as Vector2).distance_to(Vector2(3.0, -1.5)) < 1e-3,
		"the door turns with the structure")
	var closed := StructureEarthworks.placement(_rec(StructureEarthworks.from_simple(
		{"rect": [-5.0, -3.0, 5.0, 3.0], "floor_y": -2.4}), 0.0, 0.0, 0.0), 10.0)
	_ok(EarthworksRuntime.door_point(closed) == null, "no daylight side, no door")


func _test_earth_temperature() -> void:
	# A desert year: 13 C in January, 35 C in July.
	var months := [13.0, 15.0, 19.0, 23.0, 28.0, 33.0, 35.0, 34.0, 30.0, 24.0, 17.0, 12.0]
	var wave := EarthTemperature.annual_wave(months)
	_near(float(wave["mean"]), 23.5833, 1e-3, "annual mean")
	_near(float(wave["amp"]), 11.5, 1e-6, "half the monthly swing")
	_ok(EarthTemperature.annual_wave([1.0, 2.0]).is_empty(), "a short year gives no wave")
	var surface_july := EarthTemperature.ground_c(wave, 0.0, 200.0)
	var deep_july := EarthTemperature.ground_c(wave, 3.0, 200.0)
	_ok(deep_july < surface_july - 3.0, "3 m down is cooler in July (%.1f vs %.1f)" % [deep_july, surface_july])
	_near(EarthTemperature.ground_c(wave, 30.0, 200.0), float(wave["mean"]), 0.01, "deep soil sits at the annual mean")
	var inside := EarthTemperature.indoor_c(wave, 1.2, 3, true, 200.0, 42.0, 35.0)
	_ok(inside < 32.0 and inside > 18.0, "a bermed room on a 42 C afternoon stays cool (%.1f)" % inside)
	var winter := EarthTemperature.indoor_c(wave, 1.2, 3, true, 15.0, 4.0, 13.0)
	_ok(winter > 8.0, "and stays warmer on a cold winter morning (%.1f)" % winter)
