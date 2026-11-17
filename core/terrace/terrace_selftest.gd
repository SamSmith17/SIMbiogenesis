extends SceneTree

## Terraced fields (offline): the stepped surface on a synthetic cone hill
## (level floors exactly level, risers continuous, cut ≈ fill, the feather),
## the paddies (concentric rings, every one spilling further down the list,
## one head at the top), the cascade (mass exact at any dt, fills top first,
## a full field passes its inflow straight out, the "keep" intake), the water
## factor, the crop clock, the hill outline, marching squares, the crop meshes
## and the record store. Carries EXPECTED_CHECKS (a runtime error aborts a
## test function while PASS still prints). --import first.

const EXPECTED_CHECKS := 114

var _pass := 0
var _fail := 0


func _initialize() -> void:
	_test_surface()
	_test_paddies()
	_test_cascade()
	_test_intake_and_factor()
	_test_hill_and_march()
	_test_misc()
	_test_engine()
	_test_farm_people()
	_test_farm_machines()
	_test_modelled_crews()
	_test_steps_and_build()
	_test_rows()
	_test_engine_people()
	var total := _pass + _fail
	if total != EXPECTED_CHECKS:
		print("FAIL check count %d, expected %d (a test function stopped early?)" % [total, EXPECTED_CHECKS])
		_fail += 1
	print("terrace_selftest: %d passed, %d failed — %s" % [_pass, _fail, "PASS" if _fail == 0 else "FAIL"])
	quit(0 if _fail == 0 else 1)


func _ok(c: bool, what: String) -> void:
	if c:
		_pass += 1
	else:
		_fail += 1
		print("  FAILED: ", what)


static func _cone(x: float, z: float) -> float:
	return 50.0 - 0.25 * Vector2(x, z).length()


static func _circle(r: float, n: int = 48, c := Vector2.ZERO) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in n:
		var a := TAU * float(i) / float(n)
		out.append(c + Vector2(cos(a), sin(a)) * r)
	return out


func _rec(poly: PackedVector2Array) -> Dictionary:
	var r := TerraceField.defaults()
	r["id"] = "t"
	r["poly"] = TerraceField.poly_to_array(poly)
	return r


func _test_surface() -> void:
	var rec := _rec(_circle(60.0))
	var s := TerraceField.solve(rec, Callable(self, "_cone"))
	_ok(not s.is_empty(), "a cone hill solves")
	if s.is_empty():
		for _i in 9:
			_ok(false, "solve")
		return
	var g: Dictionary = s["grid"]
	var cols := int(g["cols"])
	var m: PackedInt32Array = g["m"]
	var d: PackedFloat32Array = g["d"]
	var fl: PackedFloat32Array = g["flat"]
	var tg: PackedFloat32Array = g["target"]
	var datum := float(s["datum"])
	var hh := float(s["step_h"])
	var worst_floor := 0.0
	var floors := 0
	var worst_jump := 0.0
	for k in m.size():
		if m[k] == TerraceField.NO_STEP:
			continue
		if absf(d[k]) <= fl[k]:
			floors += 1
			worst_floor = maxf(worst_floor, absf(tg[k] - (datum + float(m[k]) * hh)))
		if k % cols < cols - 1 and m[k + 1] != TerraceField.NO_STEP:
			worst_jump = maxf(worst_jump, absf(tg[k + 1] - tg[k]))
	_ok(floors > 500, "there are level floors (%d samples)" % floors)
	_ok(worst_floor < 1e-3, "every floor sample is exactly at its step's level (worst %.4f m)" % worst_floor)
	_ok(worst_jump <= hh * 1.05, "no jump between neighbours bigger than a step (%.2f m)" % worst_jump)
	var st: Dictionary = s["stats"]
	var steps := int(st["steps"])
	_ok(steps >= 9 and steps <= 15, "about 15 m of hill in 1.2 m steps (%d)" % steps)
	var cut := float(st["cut_m3"])
	var fill := float(st["fill_m3"])
	_ok(cut > 0.0 and fill > 0.0 and absf(cut - fill) / (cut + fill) < 0.3,
		"cut and fill roughly balance (%.0f / %.0f m³)" % [cut, fill])
	# Outside the outline nothing moves; just inside the feather, little.
	var deltas: Dictionary = s["deltas"]
	var out_any := false
	for k in deltas.keys():
		var key: Vector2i = k
		var p := Vector2(float(key.x), float(key.y)) * float(g["cell"])
		if p.length() > 61.0:
			out_any = true
	_ok(not out_any, "no cut outside the outline")
	var edge_max := 0.0
	for k in deltas.keys():
		var key2: Vector2i = k
		var p2 := Vector2(float(key2.x), float(key2.y)) * float(g["cell"])
		if p2.length() > 59.0:
			edge_max = maxf(edge_max, absf(float(deltas[k])))
	_ok(edge_max < 0.3, "the feather meets the natural ground at the edge (%.2f m)" % edge_max)
	# The riser law is continuous across a band's edge.
	var a := TerraceField.stepped_t(3, 0.4999, 0.3)
	var b := TerraceField.stepped_t(4, -0.4999, 0.3)
	_ok(absf(a - b) < 0.002, "stepped_t meets itself at the band edge (%.4f vs %.4f)" % [a, b])
	_ok(not TerraceField.outline_problem(_circle(3.0)).is_empty(), "a tiny outline is refused")
	var ah := TerraceField.auto_step_h(_circle(60.0), Callable(self, "_cone"))
	_ok(absf(ah - 1.8) < 0.15, "Auto: a 25 %% slope gets steps about 7 m wide (%.1f m high)" % ah)


func _test_paddies() -> void:
	var rec := _rec(_circle(60.0))
	var s := TerraceField.solve(rec, Callable(self, "_cone"))
	var pz: Array = s.get("paddies", [])
	_ok(pz.size() >= 8, "rings make paddies (%d)" % pz.size())
	var order_ok := true
	var links_ok := true
	var last_m := 1 << 30
	for i in pz.size():
		var p: Dictionary = pz[i]
		if int(p["m"]) > last_m:
			order_ok = false
		last_m = int(p["m"])
		for t in (p["down"] as PackedInt32Array):
			if t <= i:
				links_ok = false
	_ok(order_ok, "paddies are listed highest first")
	_ok(links_ok, "every paddy spills further down the list")
	var heads: PackedInt32Array = s.get("heads", PackedInt32Array())
	_ok(heads.size() == 1 and heads[0] == 0, "the top paddy is the one head (%s)" % str(heads))
	var last: Dictionary = pz[pz.size() - 1]
	_ok((last["down"] as PackedInt32Array).is_empty(), "the lowest paddy spills out of the field")
	var mid: Dictionary = pz[pz.size() / 2]
	var w := 0.0
	for x in (mid["dw"] as PackedFloat32Array):
		w += float(x)
	_ok(absf(w - 1.0) < 1e-4, "a paddy's spill shares add up to 1")
	_ok(float(mid["catch"]) >= float(mid["area"]), "a paddy's catchment holds its floor")
	var table := TerraceField.paddy_table(s, rec)
	_ok(table.size() == pz.size() and float(table[0][2]) > 0.0, "the paddy table has a capacity per paddy")


func _test_cascade() -> void:
	# A chain of three: 10 m² each, 1500 L capacity, 0 -> 1 -> 2 -> out.
	var table: Array = [
		[10.0, 10.0, 1500.0, [1], [1.0]],
		[10.0, 10.0, 1500.0, [2], [1.0]],
		[10.0, 10.0, 1500.0, [], []],
	]
	var store := PackedFloat64Array([0.0, 0.0, 0.0])
	var res := TerraceField.cascade_step(table, store, [0], 1000.0, 0.0, 0.0, 1.0)
	var st: PackedFloat64Array = res["store"]
	_ok(absf(st[0] - 1000.0) < 1e-6 and st[1] == 0.0, "the top fills first")
	res = TerraceField.cascade_step(table, st, [0], 1000.0, 0.0, 0.0, 1.0)
	st = res["store"]
	_ok(absf(st[0] - 1500.0) < 1e-6 and absf(st[1] - 500.0) < 1e-6, "then spills to the next")
	_ok(float((res["spill"] as PackedFloat32Array)[0]) > 0.0, "the top reports its spill")
	for _i in 10:
		res = TerraceField.cascade_step(table, st, [0], 1000.0, 0.0, 0.0, 1.0)
		st = res["store"]
	_ok(absf(float(res["outflow_lph"]) - 1000.0) < 1e-3, "a full field passes its inflow straight out")
	# Mass: random steps with rain and losses.
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var worst := 0.0
	st = PackedFloat64Array([300.0, 1400.0, 20.0])
	for _j in 200:
		var dt := rng.randf_range(0.01, 3.0)
		var before := st[0] + st[1] + st[2]
		var r2 := TerraceField.cascade_step(table, st, [0], rng.randf_range(0.0, 900.0),
			rng.randf_range(0.0, 20.0), rng.randf_range(0.0, 2.0), dt)
		var after_s: PackedFloat64Array = r2["store"]
		var after := after_s[0] + after_s[1] + after_s[2]
		var bal := before + float(r2["in_l"]) + float(r2["rain_l"]) - float(r2["lost_l"]) \
			- float(r2["outflow_lph"]) * dt
		worst = maxf(worst, absf(after - bal))
		st = after_s
	_ok(worst < 1e-6, "the cascade is mass-exact at any dt (worst %.9f L)" % worst)
	# A split: one paddy spilling to two by shares.
	var split: Array = [[10.0, 10.0, 0.0, [1, 2], [0.75, 0.25]], [10.0, 10.0, 1e9, [], []],
		[10.0, 10.0, 1e9, [], []]]
	var r3 := TerraceField.cascade_step(split, PackedFloat64Array([0, 0, 0]), [0], 400.0, 0.0, 0.0, 1.0)
	var s3: PackedFloat64Array = r3["store"]
	_ok(absf(s3[1] - 300.0) < 1e-6 and absf(s3[2] - 100.0) < 1e-6, "a spill splits by shared edge")
	# Losses never take more than is there.
	var r4 := TerraceField.cascade_step(table, PackedFloat64Array([5, 0, 0]), [0], 0.0, 0.0, 50.0, 1.0)
	_ok((r4["store"] as PackedFloat64Array)[0] >= 0.0 and absf(float(r4["lost_l"]) - 5.0) < 1e-9,
		"losses stop at an empty paddy")


func _test_intake_and_factor() -> void:
	var table: Array = [[10.0, 10.0, 1500.0, [1], [1.0]], [10.0, 10.0, 1500.0, [], []]]
	var rec := TerraceField.defaults()
	rec["inflow_lph"] = 5000.0
	var full := PackedFloat64Array([1500.0, 1500.0])
	_ok(TerraceField.intake_lph(rec, table, full, 0.0, 0.0, 1.0) == 0.0, "keep: a full field takes nothing")
	var take := TerraceField.intake_lph(rec, table, full, 0.0, 1.0, 1.0)
	_ok(absf(take - 20.0) < 1e-6, "keep: a full field takes its losses (%.2f L/h)" % take)
	_ok(TerraceField.intake_lph(rec, table, PackedFloat64Array([0, 0]), 0.0, 0.0, 1.0) == 3000.0,
		"keep: an empty field takes what fills it")
	_ok(TerraceField.intake_lph(rec, table, PackedFloat64Array([0, 0]), 0.0, 0.0, 0.1) == 5000.0,
		"keep: never more than the set rate")
	rec["inflow_mode"] = "off"
	_ok(TerraceField.intake_lph(rec, table, PackedFloat64Array([0, 0]), 0.0, 1.0, 1.0) == 0.0, "off: nothing")
	rec["inflow_mode"] = "pump"
	_ok(TerraceField.intake_lph(rec, table, full, 0.0, 0.0, 1.0) == 5000.0, "pump: the set rate, full or not")
	var wet := TerraceField.defaults()
	_ok(absf(TerraceField.water_factor(wet, table, full) - 1.0) < 1e-6, "flooded rice in full paddies: 1")
	_ok(absf(TerraceField.water_factor(wet, table, PackedFloat64Array([0, 0])) - 0.35) < 1e-6,
		"flooded rice in dry paddies: 0.35")
	var dry := TerraceField.defaults()
	dry["flooded"] = false
	dry["crop"] = "potato"
	var cap := TerraceField.capacity_l(10.0, dry)
	_ok(absf(cap - 800.0) < 1e-6, "a dry step holds its root zone's water (%.0f L)" % cap)
	var dt2: Array = [[10.0, 10.0, cap, [], []]]
	_ok(absf(TerraceField.water_factor(dry, dt2, PackedFloat64Array([cap * 0.5])) - 1.0) < 1e-6,
		"a dry crop is unstressed above half its soil water")
	_ok(TerraceField.et0_mm_day(25.0) > 4.0 and TerraceField.et0_mm_day(25.0) < 7.0, "ET0 at 25 °C is 4–7 mm/day")


func _test_hill_and_march() -> void:
	var outline := TerraceField.hill_outline(Callable(self, "_cone"), Vector2(30.0, 0.0), 80.0)
	_ok(outline.size() > 20, "a click on the hill's side outlines it (%d points)" % outline.size())
	_ok(Geometry2D.is_point_in_polygon(Vector2.ZERO, outline), "the outline holds the summit")
	var r_mean := 0.0
	for p in outline:
		r_mean += p.length()
	r_mean /= float(maxi(outline.size(), 1))
	_ok(r_mean > 26.0 and r_mean < 36.0, "it reaches about as far as the click (%.1f m)" % r_mean)
	_ok(TerraceField.hill_outline(Callable(self, "_cone"), Vector2.ZERO, 80.0).is_empty(),
		"a click on the summit has nothing above it")
	# Marching squares on a disc of radius 10 (field = 10 − r).
	var cols := 41
	var field := PackedFloat32Array()
	field.resize(cols * cols)
	for j in cols:
		for i in cols:
			field[j * cols + i] = 10.0 - Vector2(float(i - 20), float(j - 20)).length()
	var tris := PackedVector3Array()
	var segs := PackedVector2Array()
	TerraceMesh.march(field, cols, cols, Vector2(-20, -20), 1.0, 0.0, tris, segs)
	var area := 0.0
	var wound := true
	var i := 0
	while i + 2 < tris.size():
		var c := (tris[i + 1] - tris[i]).cross(tris[i + 2] - tris[i])
		area += c.length() * 0.5
		if c.dot(Vector3.UP) > 1e-9:
			wound = false
		i += 3
	_ok(absf(area - PI * 100.0) / (PI * 100.0) < 0.02, "marching squares fill a disc's area (%.1f m²)" % area)
	_ok(wound, "every surface triangle faces up for Godot")
	var perim := 0.0
	i = 0
	while i + 1 < segs.size():
		perim += segs[i].distance_to(segs[i + 1])
		i += 2
	_ok(absf(perim - TAU * 10.0) / (TAU * 10.0) < 0.03, "its edge is the circle (%.1f m)" % perim)


func _test_misc() -> void:
	var rec := TerraceField.defaults()
	rec["plant_abs_h"] = 100.0
	_ok(not bool(TerraceField.crop_phase(rec, 99.0)["planted"]), "nothing before the sowing")
	var ph := TerraceField.crop_phase(rec, 100.0 + 120.0 * 24.0 * 1.5)
	_ok(int(ph["cycle"]) == 1 and absf(float(ph["f"]) - 0.5) < 1e-6, "half way through the second rice crop")
	rec["crop"] = "fallow"
	_ok(not bool(TerraceField.crop_phase(rec, 5000.0)["planted"]), "fallow grows nothing")
	for id in ["rice", "reed", "taro"]:
		_ok(GardenCrops.triangle_count(id) > 20, "the %s mesh is built" % id)
	var layer := TerraceLayer.new()
	var a := layer.add(_circle(30.0, 12))
	var b := layer.add(_circle(30.0, 12, Vector2(100, 0)))
	_ok(str(a["id"]) != str(b["id"]), "fields get their own ids")
	_ok(layer.field_at(Vector2(100, 5)) == str(b["id"]), "a point finds its field")
	_ok(not layer.overlapping(_circle(10.0, 8, Vector2(110, 0))).is_empty(), "an overlapping outline is found")
	layer.checkpoint()
	layer.update(str(a["id"]), {"step_h": 2.0})
	layer.undo()
	_ok(float(layer.find(str(a["id"]))["step_h"]) == 1.2, "undo puts a field back")
	var j := TerraceLayer._to_json(TerraceField.defaults())
	_ok(j["datum"] == null and is_nan(float(TerraceLayer._from_json(j)["datum"])), "the auto datum survives JSON")


## The flow engine running a terrace node: water pumped from a store fills
## the top step first, cascades down, spills into the overflow store; the
## water balance closes against the node's own readings; after a crop cycle
## the harvest lands in the food store.
func _test_engine() -> void:
	var model = load("res://system_graph/data/graph_model.gd").new()
	model.add_item({"id": "src", "type": "resource", "x": 0.0, "y": 0.0, "width": 90.0, "height": 100.0,
		"specs": {"name": "Cistern", "resource_kind": "water", "capacity_qty": 10000.0,
			"capacity_unit": "L", "level": 1.0}})
	model.add_item({"id": "sink", "type": "resource", "x": 0.0, "y": 300.0, "width": 90.0, "height": 100.0,
		"specs": {"name": "Pond", "resource_kind": "water", "capacity_qty": 10000.0,
			"capacity_unit": "L", "level": 0.0}})
	model.add_item({"id": "food", "type": "resource", "x": 200.0, "y": 300.0, "width": 90.0, "height": 100.0,
		"specs": {"name": "Rice store", "resource_kind": "food", "capacity_qty": 1000000.0,
			"capacity_unit": "kg", "level": 0.0}})
	var table: Array = [[10.0, 10.0, 1500.0, [1], [1.0], 3, "rice", true],
		[10.0, 10.0, 1500.0, [2], [1.0], 2, "rice", true], [10.0, 10.0, 1500.0, [], [], 1, "rice", true]]
	var specs := {"name": "Paddies", "terrace_id": "tf_1", "crop": "rice", "flooded": true, "labour": "free",
		"bund_h": 0.15, "inflow_mode": "pump", "inflow_lph": 1000.0, "perc_mm_d": 0.0,
		"plant_abs_h": 0.0, "terrace_table": table, "terrace_heads": [0], "area_m2": 30.0}
	model.add_item({"id": "tf", "type": "plant", "x": 100.0, "y": 150.0, "width": 180.0, "height": 140.0,
		"specs": specs})
	model.add_connection({"polarity": "resource", "resource_type": "water", "source_item_id": "src",
		"source_handle_id": "output", "target_item_id": "tf", "target_handle_id": "water_in"})
	model.add_connection({"polarity": "resource", "resource_type": "water", "source_item_id": "tf",
		"source_handle_id": "water_out", "target_item_id": "sink", "target_handle_id": "input"})
	model.add_connection({"polarity": "resource", "resource_type": "food", "source_item_id": "tf",
		"source_handle_id": "harvest_out", "target_item_id": "food", "target_handle_id": "input"})
	var eng = load("res://system_graph/resource_flow_engine.gd").new()
	eng.setup(model, null)
	eng.rain_rate_override_mmh = 0.0
	eng.sun_ghi_override_wm2 = 0.0
	eng.wind_temp_override_c = 5.0
	eng.simulate_step_for_test(0.0, 0.0)
	eng.simulate_step_for_test(1.0, 1.0)
	var s1: Dictionary = model.get_item("tf")["specs"]
	var f1: Array = s1.get("terrace_fill", [])
	_ok(f1.size() == 3 and float(f1[0]) > 0.6 and float(f1[1]) == 0.0,
		"the engine fills the top step first (%s)" % str(f1))
	for h in range(2, 9):
		eng.simulate_step_for_test(float(h), 1.0)
	var s2: Dictionary = model.get_item("tf")["specs"]
	var f2: Array = s2.get("terrace_fill", [])
	_ok(f2.size() == 3 and float(f2[2]) > 0.97, "the water cascades to the bottom step (%s)" % str(f2))
	var sink_l := _level(model, "sink") * 10000.0
	_ok(sink_l > 100.0, "what spills off the bottom fills the overflow store (%.0f L)" % sink_l)
	var used := (1.0 - _level(model, "src")) * 10000.0
	var held := float(s2.get("water_held_l", 0.0))
	# 8 h × ET at 5 °C on 30 m² is about 10 L; the readings round to 10 L.
	_ok(absf(used - held - sink_l) < 40.0,
		"the water balance closes (used %.0f, held %.0f, out %.0f L)" % [used, held, sink_l])
	# A crop cycle in the sun, kept full: the harvest goes to the store.
	eng.sun_ghi_override_wm2 = 400.0
	specs = (model.get_item("tf")["specs"] as Dictionary).duplicate(true)
	specs["inflow_mode"] = "keep"
	model.update_item("tf", {"specs": specs})
	var h := 9.0
	while h < 122.0 * 24.0:
		h += 24.0
		eng.simulate_step_for_test(h, 24.0)
	var food_kg := _level(model, "food") * 1000000.0
	_ok(food_kg > 1.0, "a rice harvest reaches the food store (%.1f kg)" % food_kg)
	var s3: Dictionary = model.get_item("tf")["specs"]
	_ok(float(s3.get("last_harvest_kg", 0.0)) > 1.0, "the node says what the last harvest was")
	_ok(float(s3.get("standing_kg", 999.0)) < food_kg, "the field is cut back after the harvest")
	var hs := GraphPortService.resolved_handles(model.get_item("tf"), {})
	var ids: Array = []
	for hh in hs:
		ids.append(str((hh as Dictionary).get("id", "")))
	_ok(ids.has("water_in") and ids.has("water_out") and ids.has("harvest_out") and ids.has("residue_out"),
		"a terrace node has its water, harvest and straw ports (%s)" % str(ids))


static func _level(model, id: String) -> float:
	return float((model.get_item(id).get("specs", {}) as Dictionary).get("level", 0.0))


## A rice paddy worked by people: every job waits for its crew, the hours are
## the job's, a missed weeding costs yield, the harvest comes in as it is cut.
func _test_farm_people() -> void:
	var table: Array = [[500.0, 520.0, 75000.0, [], [], 4, "rice", true]]
	var fs := TerraceFarm.fresh(table)
	var env := {"labour": "people", "hour": 10.0, "par_wm2": 180.0, "month": 7, "wf": [1.0],
		"built": [true], "credit": {}}
	var r := TerraceFarm.step(table, fs, 0.0, 1.0, env)
	fs = r["fs"]
	var jobs := TerraceFarm.open_jobs(table, fs)
	_ok(jobs.size() == 1 and str(jobs[0]["task"]) == "prep",
		"a new paddy first needs preparing (%s)" % str(jobs))
	var need := float(jobs[0]["need_h"])
	_ok(absf(need - 300.0 * 0.05) < 0.01, "preparing 500 m² of rice is 15 person-hours (%.2f)" % need)
	_ok(int(jobs[0]["crew_max"]) >= 6 and int(jobs[0]["crew_min"]) == 1,
		"a big paddy takes a full crew (%s)" % str(jobs[0]))
	# No credit: nothing happens however long it waits.
	for h in range(1, 48):
		fs = TerraceFarm.step(table, fs, float(h), 1.0, env)["fs"]
	_ok(str((fs["p"][0] as Dictionary)["st"]) == "prep", "with no crew the paddy waits")
	var seq := int(jobs[0]["seq"])
	env["credit"] = {"0": [seq, 0.5]}
	r = TerraceFarm.step(table, fs, 48.0, 1.0, env)
	fs = r["fs"]
	_ok(absf(float(r["labour_h"]) - need * 0.5) < 0.01, "half the job is half its hours")
	env["credit"] = {"0": [seq, 1.0]}
	fs = TerraceFarm.step(table, fs, 49.0, 1.0, env)["fs"]
	jobs = TerraceFarm.open_jobs(table, fs)
	_ok(jobs.size() == 1 and str(jobs[0]["task"]) == "plant", "then it is transplanted (%s)" % str(jobs))
	env["credit"] = {"0": [int(jobs[0]["seq"]), 1.0]}
	fs = TerraceFarm.step(table, fs, 50.0, 1.0, env)["fs"]
	var p: Dictionary = fs["p"][0]
	_ok(str(p["st"]) == "grow" and absf(float(p["sow"]) - 50.0) < 0.01, "planted, it grows from that hour")
	# Grow through the season; do the first two weedings, miss the third.
	var h := 50.0
	var done_rounds := 0
	var food := 0.0
	while h < 50.0 + 140.0 * 24.0:
		h += 6.0
		var c := {}
		for j in TerraceFarm.open_jobs(table, fs):
			if str(j["task"]) == "tend" and done_rounds < 2:
				c["0"] = [int(j["seq"]), 1.0]
				done_rounds += 1
			elif str(j["task"]) == "harvest":
				c["0"] = [int(j["seq"]), minf(float(j["frac"]) + 0.5, 1.0)]
		env["credit"] = c
		var rr := TerraceFarm.step(table, fs, h, 6.0, env)
		fs = rr["fs"]
		food += float(rr["food_kg"])
	var led: Dictionary = fs["ledger"]
	_ok(int(led["missed"]) >= 1, "a weeding left undone is missed (%d)" % int(led["missed"]))
	_ok(food > 10.0, "the cut rice comes in (%.1f kg from 500 m²)" % food)
	_ok(str((fs["p"][0] as Dictionary)["st"]) == "prep", "after the harvest it is prepared again")
	var sumh := TerraceFarm.ledger_summary(led)
	var expect := 15.0 + 12.5 + 2.0 * 3.75 + 17.5
	_ok(absf(float(sumh["labour_h"]) - expect) < 0.05,
		"the ledger counts the hours worked (%.2f of %.2f)" % [float(sumh["labour_h"]), expect])
	_ok(absf(float(sumh["work_kwh"]) - expect * 0.08) < 0.01, "80 Wh of work a person-hour")
	_ok(absf(float(sumh["food_kwh"]) - expect * 0.08 / 0.25) < 0.02, "and four times that in food")
	var est := TerraceFarm.season_estimate([[10000.0, 10000.0, 1.0, [], [], 1, "rice", true]])
	_ok(absf(float(est["hand_h"]) - 1200.0) < 0.1, "a hectare of rice by hand is 1,200 h a season")
	_ok(float(est["machine_op_h"]) < 400.0 and float(est["fuel_l"]) > 0.0,
		"machines take far fewer hours and some fuel (%.0f h, %.0f L)" % [float(est["machine_op_h"]), float(est["fuel_l"])])
	# A reed bed is planted once and regrows after each cut.
	var rt: Array = [[200.0, 200.0, 30000.0, [], [], 1, "reed", true]]
	var rs := TerraceFarm.fresh(rt)
	var envr := {"labour": "free", "hour": 10.0, "par_wm2": 180.0, "month": 7, "wf": [1.0]}
	rs = TerraceFarm.step(rt, rs, 0.0, 1.0, envr)["fs"]
	_ok(str((rs["p"][0] as Dictionary)["st"]) == "grow", "reeds need no preparing; planted, they grow")
	var bio := 0.0
	var hh := 0.0
	while hh < 370.0 * 24.0:
		hh += 24.0
		var rr2 := TerraceFarm.step(rt, rs, hh, 24.0, envr)
		rs = rr2["fs"]
		bio += float(rr2["biomass_kg"])
	_ok(bio > 0.0 and str((rs["p"][0] as Dictionary)["st"]) == "grow",
		"a cut reed bed grows again with no replanting (%.0f kg)" % bio)


## Where no live crew can work (a pre-render, simkit) people's jobs move on
## at a modelled crew's pace, by day.
func _test_modelled_crews() -> void:
	var table: Array = [[400.0, 400.0, 60000.0, [], [], 1, "rice", true]]
	var fs := TerraceFarm.fresh(table)
	var env := {"labour": "people", "hour": 9.0, "crews": true}
	var r := TerraceFarm.step(table, fs, 9.0, 1.0, env)
	r = TerraceFarm.step(table, r["fs"], 10.0, 1.0, env)
	var need := TerraceFarm.job_hours("rice", "prep", 400.0)
	var crew := float(TerraceFarm.crew_for("prep", 400.0)[1])
	var p: Dictionary = (r["fs"] as Dictionary)["p"][0]
	_ok(absf(float(p["frac"]) - minf(2.0 * crew * TerraceFarm.CREW_RATE / need, 1.0)) < 1e-4 or str(p["st"]) == "plant",
		"a modelled crew prepares the paddy at its pace (%.2f)" % float(p["frac"]))
	var night := TerraceFarm.step(table, TerraceFarm.fresh(table), 22.0, 1.0, {"labour": "people", "hour": 22.0, "crews": true})
	night = TerraceFarm.step(table, night["fs"], 23.0, 1.0, {"labour": "people", "hour": 23.0, "crews": true})
	_ok(float(((night["fs"] as Dictionary)["p"][0] as Dictionary)["frac"]) == 0.0, "and not at night")


## Machines: the operator's hours are a share of the hand hours, only by day,
## and they burn fuel.
func _test_farm_machines() -> void:
	var table: Array = [[1000.0, 1000.0, 150000.0, [], [], 1, "rice", true]]
	var fs := TerraceFarm.fresh(table)
	var env := {"labour": "machines", "hour": 2.0, "par_wm2": 0.0, "month": 7, "wf": [1.0]}
	var r := TerraceFarm.step(table, fs, 2.0, 1.0, env)
	fs = r["fs"]
	_ok(float((fs["p"][0] as Dictionary)["frac"]) == 0.0, "machines do not work at night")
	env["hour"] = 9.0
	var op := 0.0
	var fuel := 0.0
	var h := 9.0
	for i in 20:
		if str((fs["p"][0] as Dictionary)["task"]) != "prep":
			break
		r = TerraceFarm.step(table, fs, h, 0.5, env)
		fs = r["fs"]
		op += float(r["op_h"])
		fuel += float(r["fuel_l"])
		h += 0.5
	var expect_op := 30.0 * 0.05
	_ok(absf(op - expect_op) < 0.01, "the tractor tills 1,000 m² in %.2f h (%.2f)" % [expect_op, op])
	_ok(absf(fuel - expect_op * 4.0) < 0.01, "burning 4 L an hour (%.2f L)" % fuel)
	_ok(str((fs["p"][0] as Dictionary)["st"]) == "plant", "then it is planted")
	var mj := TerraceFarm.open_jobs(table, fs, "machines")
	_ok(mj.size() == 1 and str(mj[0]["task"]) == "plant", "with the tractor, people still plant (%s)" % str(mj))
	# One tractor: two paddies are tilled one after the other.
	var t3: Array = [[500.0, 500.0, 75000.0, [1], [1.0], 2, "rice", true],
		[500.0, 500.0, 75000.0, [], [], 1, "rice", true]]
	var f3 := TerraceFarm.fresh(t3)
	for hh in 2:
		f3 = TerraceFarm.step(t3, f3, 9.0 + float(hh) * 0.25, 0.25, {"labour": "machines", "hour": 9.0})["fs"]
	var fa := float((f3["p"][0] as Dictionary)["frac"])
	var fb := float((f3["p"][1] as Dictionary)["frac"])
	_ok(fa > 0.0 and fb == 0.0, "one tractor works one paddy at a time (%.2f, %.2f)" % [fa, fb])
	# A dry diesel store stops the tractor.
	var t2: Array = [[1000.0, 1000.0, 150000.0, [], [], 1, "rice", true]]
	var f2 := TerraceFarm.fresh(t2)
	var r2 := TerraceFarm.step(t2, f2, 9.0, 1.0, {"labour": "machines", "hour": 9.0, "fuel_ok": false})
	r2 = TerraceFarm.step(t2, r2["fs"], 10.0, 1.0, {"labour": "machines", "hour": 10.0, "fuel_ok": false})
	_ok(float(((r2["fs"] as Dictionary)["p"][0] as Dictionary)["frac"]) == 0.0 and float(r2["fuel_l"]) == 0.0,
		"out of diesel the tractor stops")
	_ok(TerraceFarm.machine_jobs(r2["fs"]).size() == 1, "and its job waits for it")
	var sp: Array = [[0.0, 0.0], [20.0, 0.0]]
	var a0 := TerraceFarm.tractor_at(sp, 4.0, 0.05)
	var a1 := TerraceFarm.tractor_at(sp, 4.0, 0.3)
	_ok(absf(a0["pos"].y - a1["pos"].y) > 1.0 and (a0["dir"] as Vector2).dot(a1["dir"] as Vector2) < 0.0,
		"the tractor drives up and down the paddy in passes (%s, %s)" % [a0["pos"], a1["pos"]])


## Per-step crops and water, and steps that are not dug yet.
func _test_steps_and_build() -> void:
	var rec := TerraceField.resolve({"crop": "rice", "flooded": true,
		"steps": {"2": {"crop": "potato", "flooded": false}}})
	var s2 := TerraceField.step_setting(rec, 2)
	var s3 := TerraceField.step_setting(rec, 3)
	_ok(str(s2["crop"]) == "potato" and not bool(s2["flooded"]), "a step can carry its own crop and stay dry")
	_ok(str(s3["crop"]) == "rice" and bool(s3["flooded"]), "the other steps keep the field's")
	_ok(absf(TerraceField.capacity_l(100.0, rec, 2) - 100.0 * TerraceField.DRY_AWC_M * 1000.0) < 0.1,
		"a dry step holds the soil's water")
	var solved := {"paddies": [{"m": 3, "area": 50.0, "catch": 55.0, "down": PackedInt32Array([1]),
		"dw": PackedFloat32Array([1.0])}, {"m": 2, "area": 40.0, "catch": 44.0,
		"down": PackedInt32Array(), "dw": PackedFloat32Array()}]}
	var t := TerraceField.paddy_table(solved, rec)
	_ok(int(t[1][5]) == 2 and str(t[1][6]) == "potato" and not bool(t[1][7]),
		"the paddy table carries each step's crop and water (%s)" % str(t[1]))
	var hand := rec.duplicate(true)
	hand["build_mode"] = "hand"
	hand["built"] = {"3": 1.0}
	var th := TerraceField.paddy_table(solved, hand)
	_ok(float(th[0][2]) > 0.0 and float(th[1][2]) == 0.0, "a step not yet dug holds no water")
	var fs: Dictionary = TerraceFarm.step(th, TerraceFarm.fresh(th), 0.0, 1.0,
		{"labour": "people", "built": [true, false]})["fs"]
	_ok(str((fs["p"][1] as Dictionary)["st"]) == "unbuilt" and TerraceFarm.open_jobs(th, fs).size() == 1,
		"no farm work on a step not yet dug")
	_ok(TerraceField.makes_food({"terrace_table": [[1, 1, 1, [], [], 1, "reed", true],
		[1, 1, 1, [], [], 2, "rice", true]]}), "a field with one rice step makes food")
	var est := TerraceDig.estimate(10.0, 50.0, "hand")
	_ok(absf(float(est["hours"]) - (10.0 * TerraceDig.HAND_H_PER_M3 + 50.0 * TerraceDig.HAND_FINISH_H_M2)) < 0.01,
		"digging a step by hand takes its hours per cubic metre")
	_ok(TerraceDig.cell_share(0.0, 0.0, 20.0, 0.5) == 1.0 and TerraceDig.cell_share(19.0, 0.0, 20.0, 0.5) == 0.0,
		"half dug, the start of the step is cut and its end is not")
	var sp := TerraceDig.spine_of(PackedVector2Array([Vector2(0, 0), Vector2(10, 1), Vector2(20, 0), Vector2(10, -1)]))
	_ok(float(sp["length_m"]) > 8.0 and (sp["spine"] as Array).size() >= 2, "a step's spine runs along it")
	var me := TerraceDig.estimate(10.0, 50.0, "skid_steer")
	_ok(float(me["hours"]) < float(est["hours"]) and absf(float(me["fuel_l"]) - 7.0) < 0.01,
		"a skid steer moves 10 m³ in an hour on 7 L of diesel")
	var tr := TerraceDig.estimate(10.0, 50.0, "tractor")
	_ok(float(tr["machine_h"]) > float(me["machine_h"]) and float(tr["fuel_l"]) < float(me["fuel_l"]) * 1.2,
		"the tractor's loader is slower, on less diesel an hour")
	_ok(str(TerraceField.resolve({"build_mode": "machine"})["build_mode"]) == "skid_steer",
		"an older field cut by 'machine' is cut by the skid steer")
	_ok(TerraceField.wants_fuel({"build_mode": "tractor"}) and TerraceField.wants_fuel({"labour": "machines"})
		and not TerraceField.wants_fuel({"labour": "people", "build_mode": "hand"}), "machines take a fuel port")


## A crew in a line across a plot, moving down it as the work gets done.
func _test_rows() -> void:
	var spine: Array = [[0.0, 0.0], [20.0, 0.0]]
	var a := NpcRowWork.slot(spine, 3.0, 0, 6, 0.0)
	var b := NpcRowWork.slot(spine, 3.0, 5, 6, 0.0)
	_ok(absf(a.x) < 0.01 and absf(b.x) < 0.01 and absf(a.y - b.y) > 4.0,
		"a crew spreads across the plot (%s, %s)" % [a, b])
	var c := NpcRowWork.slot(spine, 3.0, 0, 6, 0.5)
	_ok(absf(c.x - 10.0) < 0.01, "half done, the line is half way down (%s)" % c)
	var seen := {}
	for k in 6:
		seen[str(NpcRowWork.slot(spine, 3.0, k, 6, 0.3))] = true
	_ok(seen.size() == 6, "nobody stands on anybody")
	var narrow := NpcRowWork.slot(spine, 0.8, 3, 6, 0.5)
	_ok(narrow.x < 10.0, "a crew wider than the plot doubles up behind (%s)" % narrow)
	_ok(NpcWorkPose.family_for({"pose": "dig", "min_workers": 6}) == "dig",
		"a terrace chore stoops whatever its crew")


## The engine with people: jobs appear on the node; the crew's credit moves
## them on; a harvest reaches the store.
func _test_engine_people() -> void:
	var model = load("res://system_graph/data/graph_model.gd").new()
	model.add_item({"id": "src", "type": "resource", "x": 0.0, "y": 0.0, "width": 90.0, "height": 100.0,
		"specs": {"name": "Cistern", "resource_kind": "water", "capacity_qty": 100000.0,
			"capacity_unit": "L", "level": 1.0}})
	model.add_item({"id": "food", "type": "resource", "x": 200.0, "y": 300.0, "width": 90.0, "height": 100.0,
		"specs": {"name": "Rice store", "resource_kind": "food", "capacity_qty": 1000000.0,
			"capacity_unit": "kg", "level": 0.0}})
	var table: Array = [[100.0, 100.0, 15000.0, [], [], 1, "rice", true]]
	model.add_item({"id": "tf", "type": "plant", "x": 100.0, "y": 150.0, "width": 180.0, "height": 140.0,
		"specs": {"name": "Paddies", "terrace_id": "tf_2", "crop": "rice", "flooded": true,
			"labour": "people", "inflow_mode": "keep", "inflow_lph": 2000.0, "perc_mm_d": 0.0,
			"terrace_table": table, "terrace_heads": [0], "area_m2": 100.0}})
	model.add_connection({"polarity": "resource", "resource_type": "water", "source_item_id": "src",
		"source_handle_id": "output", "target_item_id": "tf", "target_handle_id": "water_in"})
	model.add_connection({"polarity": "resource", "resource_type": "food", "source_item_id": "tf",
		"source_handle_id": "harvest_out", "target_item_id": "food", "target_handle_id": "input"})
	var eng = load("res://system_graph/resource_flow_engine.gd").new()
	eng.setup(model, null)
	eng.rain_rate_override_mmh = 0.0
	eng.sun_ghi_override_wm2 = 400.0
	eng.wind_temp_override_c = 25.0
	eng.simulate_step_for_test(0.0, 0.0)
	eng.simulate_step_for_test(1.0, 1.0)
	var jobs: Array = (model.get_item("tf")["specs"] as Dictionary).get("terrace_jobs", [])
	_ok(jobs.size() == 1 and str(jobs[0]["task"]) == "prep", "the node lists the job for the crew (%s)" % str(jobs))
	var h := 1.0
	var worked := 0
	while h < 150.0 * 24.0:
		h += 12.0
		var specs: Dictionary = (model.get_item("tf")["specs"] as Dictionary).duplicate(true)
		var credit := {}
		for j in specs.get("terrace_jobs", []):
			credit[str(j["paddy"])] = [int(j["seq"]), 1.0]
			worked += 1
		specs["terrace_credit"] = credit
		model.update_item("tf", {"specs": specs})
		eng.simulate_step_for_test(h, 12.0)
	var food_kg := _level(model, "food") * 1000000.0
	_ok(worked >= 4 and food_kg > 1.0,
		"crew-worked rice is harvested into the store (%d jobs, %.1f kg)" % [worked, food_kg])
	var led: Dictionary = (model.get_item("tf")["specs"] as Dictionary).get("farm_ledger", {})
	_ok(float(led.get("labour_h", 0.0)) > 10.0, "the node counts the hours (%s)" % str(led))
	_ok((model.get_item("tf")["specs"] as Dictionary).has("terrace_farm"),
		"the farm state rides the graph save")
