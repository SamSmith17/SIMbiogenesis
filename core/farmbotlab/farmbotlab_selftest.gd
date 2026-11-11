extends SceneTree

## FarmBot designer self-test (offline):
##   Godot --headless --path . --script core/farmbotlab/farmbotlab_selftest.gd
## The per-axis motion (trapezoids by hand, axes finishing apart, a dog-leg),
## packing (hex vs square, spacing kept, nothing under the tool bay), the
## layouts, the day's jobs (water matching the schedule, contiguous segments,
## continuous positions, tools mounted for the work and put back, Z inside its
## travel, every due plant sown), the cost model's sums, the checks, the
## presets, the graph preset and the builder's pose.

const EXPECTED_CHECKS := 119

var _n := 0
var _fails := 0


func _ok(cond: bool, what: String) -> void:
	_n += 1
	if not cond:
		_fails += 1
		print("FAIL: ", what)


func _near(a: float, b: float, tol: float, what: String) -> void:
	_ok(absf(a - b) <= tol, "%s (%.4f vs %.4f)" % [what, a, b])


func _initialize() -> void:
	_test_motion()
	_test_packing()
	_test_layout()
	_test_jobs()
	_test_money()
	_test_presets_and_checks()
	_test_builder()
	_test_radial()
	if _n != EXPECTED_CHECKS:
		print("FAIL: ran %d checks, expected %d (a test function aborted?)" % [_n, EXPECTED_CHECKS])
		_fails += 1
	print("FARMBOTLAB SELFTEST %s  (%d checks, %d failed)" % ["PASS" if _fails == 0 else "FAIL", _n, _fails])
	quit(0 if _fails == 0 else 1)


func _test_motion() -> void:
	# FarmBot's defaults: 10 -> 80 mm/s over 60 mm.
	var a := (80.0 * 80.0 - 10.0 * 10.0) / 120.0
	var p := FarmBotMotion.axis_profile(1000.0, 10.0, 80.0, 60.0)
	_near(float(p["a"]), a, 1e-6, "ramp acceleration (vmax²−vmin²)/2·ramp")
	_near(float(p["t"]), 2.0 * 70.0 / a + 880.0 / 80.0, 1e-6, "long move time by hand")
	_near(FarmBotMotion.axis_pos(p, float(p["ta"])), 60.0, 1e-4, "reaches top speed after the ramp")
	_near(FarmBotMotion.axis_speed(p, float(p["ta"]) + 1.0), 80.0, 1e-6, "cruises at top speed")
	_near(FarmBotMotion.axis_speed(p, 0.0), 10.0, 1e-6, "starts at the start speed")
	_near(FarmBotMotion.axis_pos(p, float(p["t"])), 1000.0, 1e-6, "ends at the target")
	var q := FarmBotMotion.axis_profile(60.0, 10.0, 80.0, 60.0)
	_near(float(q["vp"]), sqrt(100.0 + a * 60.0), 1e-6, "a short move peaks at sqrt(vmin² + a·d)")
	_near(FarmBotMotion.axis_pos(q, float(q["t"]) * 0.5), 30.0, 1e-4, "a short move is half way at half time")
	var mono := true
	var prev := -1.0
	for i in 101:
		var x := FarmBotMotion.axis_pos(p, float(p["t"]) * float(i) / 100.0)
		if x < prev - 1e-9:
			mono = false
		prev = x
	_ok(mono, "position never runs backwards")
	var s := FarmBotSpec.resolve({})
	var lim := FarmBotMotion.limits(s)
	var A := Vector3(0, 0, -40)
	var B := Vector3(1000, 100, -40)
	var T := FarmBotMotion.move_time(lim, A, B)
	_near(T, float(p["t"]), 1e-6, "a move takes as long as its slowest axis")
	var mid := FarmBotMotion.move_pos(lim, A, B, 3.0)
	_near(mid.y, 100.0, 1e-6, "the short Y hop is done long before X (axes run separately)")
	_ok(mid.x < 300.0, "X is still on its way")
	_ok(FarmBotMotion.move_pos(lim, A, B, T).is_equal_approx(B), "the move ends on the target")
	var z := FarmBotMotion.axis_profile(100.0, 2.0, 16.0, 12.0)
	_ok(float(z["t"]) > 100.0 / 16.0, "Z is slow (lead screw)")


func _test_packing() -> void:
	# Over open ground hex holds 2/√3 = 15.5 % more; a bed's edges cut that.
	var big := Rect2(0, 0, 20, 20)
	var ratio := float(FarmBotLayout.pack(big, 0.25, true).size()) / float(FarmBotLayout.pack(big, 0.25, false).size())
	_ok(ratio > 1.12 and ratio < 1.17, "hex packs ~15 %% more than square in the open (%.3f)" % ratio)
	var rc := Rect2(0, 0, 6, 3)
	var hx := FarmBotLayout.pack(rc, 0.25, true)
	var sq := FarmBotLayout.pack(rc, 0.25, false)
	_ok(hx.size() > sq.size(), "and still more in a 6 x 3 m bed (%d vs %d)" % [hx.size(), sq.size()])
	for pts in [hx, sq]:
		var inside := true
		var minspace := INF
		for i in pts.size():
			var a: Vector2 = pts[i]
			if not rc.grow(-0.1249).has_point(a):
				inside = false
			for j in range(i + 1, mini(i + 40, pts.size())):
				minspace = minf(minspace, a.distance_to(pts[j]))
		_ok(inside, "every plant half a spacing in from the edge")
		_ok(minspace >= 0.2499, "no two plants closer than the spacing (%.4f)" % minspace)
	_ok(FarmBotLayout.pack(Rect2(0, 0, 0.1, 0.1), 0.9, true).is_empty(), "no plant in a strip far too small for it")
	# Hex is turned to suit each sowing strip, so it never holds fewer than a
	# square grid over a whole bed (it used to in narrow strips).
	var worse := []
	for id in FarmBotPresets.ORDER:
		for lay in FarmBotSpec.LAYOUTS:
			var s := FarmBotPresets.spec(str(id))
			s["crops"]["layout"] = lay
			s["crops"]["mix"].append({"crop": "kale", "share": 0.1})
			var h := int(FarmBotLayout.solve(FarmBotSpec.resolve(s))["total"])
			s["crops"]["packing"] = "square"
			var q := int(FarmBotLayout.solve(FarmBotSpec.resolve(s))["total"])
			if q > h:
				worse.append("%s/%s %d<%d" % [id, lay, h, q])
	_ok(worse.is_empty(), "hex holds at least as many as square in every preset and layout %s" % str(worse))


func _test_layout() -> void:
	var s := FarmBotSpec.resolve(FarmBotPresets.spec("genesis_xl"))
	var lay := FarmBotLayout.solve(s)
	var sum := 0
	for k in (lay["counts"] as Dictionary).keys():
		sum += int(lay["counts"][k])
	_ok(int(lay["total"]) == sum and sum > 200, "XL: %d plants, counts add up" % sum)
	var bay := FarmBotLayout.toolbay_rect(s)
	var under := 0
	for p in (lay["plants"] as Array):
		if bay.has_point(Vector2(float(p["x"]), float(p["z"]))):
			under += 1
	_ok(under == 0, "nothing grows under the tool bay")
	var inbed := true
	for p2 in (lay["plants"] as Array):
		if absf(float(p2["x"])) > 3.0 or absf(float(p2["z"])) > 1.5:
			inbed = false
	_ok(inbed, "every plant inside the bed")
	var sq := s.duplicate(true)
	sq["crops"]["packing"] = "square"
	_ok(int(FarmBotLayout.solve(FarmBotSpec.resolve(sq))["total"]) < int(lay["total"]), "square packing holds fewer")
	# Blocks: each crop's plants stay in its own lane across the bed.
	var bl := s.duplicate(true)
	bl["crops"]["layout"] = "blocks"
	var lb := FarmBotLayout.solve(FarmBotSpec.resolve(bl))
	var lanes := {}
	var clean := true
	for p3 in (lb["plants"] as Array):
		var c := str(p3["crop"])
		var zz := float(p3["z"])
		if not lanes.has(c):
			lanes[c] = Vector2(zz, zz)
		lanes[c] = Vector2(minf(lanes[c].x, zz), maxf(lanes[c].y, zz))
	var keys: Array = lanes.keys()
	for i in keys.size():
		for j in range(i + 1, keys.size()):
			var a: Vector2 = lanes[keys[i]]
			var b: Vector2 = lanes[keys[j]]
			if a.x < b.y - 0.001 and b.x < a.y - 0.001:
				clean = false
	_ok(clean, "blocks: crop lanes do not overlap across the bed")
	# Strips: crops alternate along the bed.
	var il := s.duplicate(true)
	il["crops"]["layout"] = "interleave"
	var li := FarmBotLayout.solve(FarmBotSpec.resolve(il))
	var changes := 0
	var secs: Array = li["sections"]
	for i2 in range(1, secs.size()):
		if str(secs[i2]["crop"]) != str(secs[i2 - 1]["crop"]):
			changes += 1
	_ok(changes >= secs.size() / 2, "strips: crops alternate (%d changes in %d strips)" % [changes, secs.size()])
	# A section is sown on its own day, and again one cycle later.
	var sec0: Dictionary = secs[0]
	var d0 := int(floor(float(sec0["sow_d"])))
	_ok(FarmBotLayout.sections_sown_on(li, d0).has(0), "a section is due on its sowing day")
	var cyc := int(roundf(float(GardenCrops.info(str(sec0["crop"]))["cycle"])))
	_ok(FarmBotLayout.sections_sown_on(li, d0 + cyc).has(0), "and resown a cycle later")
	_ok(not FarmBotLayout.sections_sown_on(li, d0 + 1).has(0), "and not the next day")
	var tall := s.duplicate(true)
	tall["crops"]["mix"] = [{"crop": "lettuce", "share": 0.5}, {"crop": "beans", "share": 0.5}]
	_ok((FarmBotLayout.solve(FarmBotSpec.resolve(tall))["tall"] as Array).has("beans"), "pole beans flagged taller than the gantry")


func _test_jobs() -> void:
	var s := FarmBotSpec.resolve(FarmBotPresets.spec("genesis_xl"))
	var lay := FarmBotLayout.solve(s)
	var day := FarmBotEconomics.STEADY_FROM_DAY + 3
	var plan := FarmBotJobs.day_plan(s, lay, day, true)
	var jobs: Array = plan["jobs"]
	var nw := 0
	for j in jobs:
		if str(j["id"]).begins_with("water"):
			nw += 1
	_ok(nw == (s["care"]["water_times"] as Array).size(), "a watering job per watering time")
	_near(float(plan["water_l"]), float(s["care"]["water_mm_day"]) * FarmBotSpec.area_m2(s), 0.5, "a day's water = mm/day × area")
	var ordered := true
	for i in range(1, jobs.size()):
		if float(jobs[i]["start_s"]) < float(jobs[i - 1]["start_s"]) + float(jobs[i - 1]["dur_s"]) - 1e-6:
			ordered = false
	_ok(ordered, "jobs never overlap")
	var contiguous := true
	var continuous := true
	var ztravel := true
	var tool_ok := true
	var ends_clean := true
	for jv in jobs:
		var j2: Dictionary = jv
		var segs: Array = j2["segs"]
		for i2 in segs.size():
			var sg: Dictionary = segs[i2]
			var pa: Vector3 = sg["a"]
			var pb: Vector3 = sg["b"]
			if pa.z > 0.001 or pa.z < -float(s["gantry"]["z_travel_mm"]) - 0.001 or pb.z > 0.001:
				ztravel = false
			if str(sg["act"]) == "water" and str(sg["tool"]) != "watering":
				tool_ok = false
			if (str(sg["act"]) == "seed" or str(sg["act"]) == "pick") and str(sg["tool"]) != "seeder":
				tool_ok = false
			if i2 > 0:
				var pr: Dictionary = segs[i2 - 1]
				if absf(float(pr["t0"]) + float(pr["dur"]) - float(sg["t0"])) > 1e-6:
					contiguous = false
				if not (pr["b"] as Vector3).is_equal_approx(pa):
					continuous = false
		if not segs.is_empty():
			var last: Dictionary = segs[segs.size() - 1]
			if str(last["tool"]) != "" or not (last["b"] as Vector3).is_equal_approx(FarmBotJobs.park_pos(s)):
				ends_clean = false
			_near(float(last["t0"]) + float(last["dur"]), float(j2["dur_s"]), 1e-6, "%s: segments fill the job" % str(j2["label"]))
	_ok(contiguous, "segments follow one another in time")
	_ok(continuous, "each segment starts where the last ended")
	_ok(ztravel, "Z stays inside its travel")
	_ok(tool_ok, "water from the nozzle, seeds from the seeder")
	_ok(ends_clean, "every job puts its tool back and parks")
	var fast := FarmBotJobs.day_plan(s, lay, day, false)
	_near(float(fast["busy_s"]), float(plan["busy_s"]), 1e-6, "the totals-only plan times the same day")
	var j0: Dictionary = jobs[0]
	var r0 := FarmBotJobs.sample_job(j0, 0.0)
	_ok((r0["pos"] as Vector3).is_equal_approx((j0["segs"][0] as Dictionary)["a"]), "a job starts where its first segment does")
	var idle := FarmBotJobs.sample_day(plan, 3.0 * 3600.0)
	_ok(not bool(idle["busy"]), "at 3 am the robot is idle")
	var busy := FarmBotJobs.sample_day(plan, float(j0["start_s"]) + 10.0)
	_ok(bool(busy["busy"]), "a few seconds into a job it is working")
	# A sowing day: every plant of the due sections sown, once.
	var sow_day := -1
	var due: Array = []
	for d in 200:
		due = FarmBotLayout.sections_sown_on(lay, d)
		if not due.is_empty():
			sow_day = d
			break
	var want := 0
	for i3 in due:
		want += int((lay["sections"][i3] as Dictionary)["n"])
	var sp := FarmBotJobs.day_plan(s, lay, sow_day, false)
	_ok(sow_day >= 0 and int(sp["seeded"]) == want, "day %d: %d of %d due plants sown" % [sow_day, int(sp["seeded"]), want])
	_ok(FarmBotJobs.weeds_on(s, 10) == FarmBotJobs.weeds_on(s, 10), "the weeds found on a day are the same every time")
	_ok(FarmBotJobs.weeds_on(s, 10).size() == int(roundf(FarmBotJobs.WEEDS_PER_M2_DAY * 18.0 * 2.0)), "weeds ∝ area × days since the last pass")
	var none := s.duplicate(true)
	none["tools"]["watering"] = false
	var pn := FarmBotJobs.day_plan(FarmBotSpec.resolve(none), lay, day, false)
	_near(float(pn["water_l"]), 0.0, 1e-9, "no nozzle, no watering")


func _test_money() -> void:
	var s := FarmBotSpec.resolve(FarmBotPresets.spec("genesis_xl"))
	var g := FarmBotSpec.resolve(FarmBotPresets.spec("genesis"))
	_near(FarmBotSpec.kit_price_usd(g), 3500.0, 1.0, "Genesis kit ≈ $3,500 (FarmBot docs)")
	_near(FarmBotSpec.kit_price_usd(s), 4500.0, 1.0, "XL kit ≈ $4,500")
	var own := s.duplicate(true)
	own["cost"]["kit_usd"] = 6000.0
	_near(FarmBotSpec.kit_price_usd(FarmBotSpec.resolve(own)), 6000.0, 1e-6, "a typed price wins")
	var d := FarmBotDesign.solve(s)
	var m: Dictionary = d["money"]
	_near(float(m["saved_h_year"]), float(m["hand"]["h_year"]) - float(m["still_h_year"]), 1e-6, "saved = hand work − what it still needs")
	_near(float(m["net_usd_year"]), float(m["saved_h_year"]) * 20.0 - float(m["running_usd_year"]), 1e-6, "net = saved × rate − running")
	_near(float(m["payback_years"]), float(m["capital_usd"]) / float(m["net_usd_year"]), 1e-6, "payback = capital ÷ net")
	_ok(float(m["saved_h_year"]) > 0.0, "the XL saves hand work (%.0f h a year)" % float(m["saved_h_year"]))
	var poor := s.duplicate(true)
	poor["cost"]["labor_usd_h"] = 0.0
	_ok(is_inf(float(FarmBotDesign.solve(poor)["money"]["payback_years"])), "unpaid labour: it never pays back")
	_ok(FarmBotDesign.solve(s) == d, "the solve is cached by the spec")
	var big := FarmBotSpec.resolve(FarmBotPresets.spec("market_row_18"))
	_ok(float(FarmBotDesign.solve(big)["money"]["saved_h_year"]) > float(m["saved_h_year"]), "a bigger bed saves more hours")


func _test_presets_and_checks() -> void:
	for id in FarmBotPresets.ORDER:
		var d := FarmBotDesign.solve(FarmBotPresets.spec(str(id)))
		var errs := 0
		for c in (d["checks"] as Array):
			if str(c["level"]) == "error":
				errs += 1
		_ok(errs == 0 and int(d["layout"]["total"]) > 0, "%s: plants, no errors" % str(id))
	var wide := FarmBotSpec.resolve({"bed": {"width_m": 4.0}})
	_ok(_has_check(FarmBotDesign.solve(wide), "3 m"), "a 4 m gantry is warned about")
	var long := FarmBotSpec.resolve({"bed": {"length_m": 20.0}})
	_ok(_has_check(FarmBotDesign.solve(long), "belt"), "a 20 m track is warned about")
	var tall := FarmBotSpec.resolve({"crops": {"mix": [{"crop": "tomato", "share": 1.0}]}})
	_ok(_has_check(FarmBotDesign.solve(tall), "taller"), "tomatoes over the gantry are warned about")
	var heavy := FarmBotSpec.resolve({"bed": {"length_m": 40.0, "width_m": 3.0},
		"crops": {"mix": [{"crop": "carrot", "share": 1.0}]}, "care": {"water_times": [5.0, 9.0, 13.0, 17.0, 21.0]}})
	var hd := FarmBotDesign.solve(heavy)
	_ok(float(hd["robot"]["max_busy_h"]) > 16.0 and _has_check(hd, "day"), "a day of work too long is flagged (%.1f h)" % float(hd["robot"]["max_busy_h"]))
	var p := ComponentPresets.designed_farmbot_preset(FarmBotPresets.spec("market_row_18"))
	_near(float(p["specs"]["area_m2"]), 45.0, 1e-6, "the graph node's area is the bed's")
	_ok(str(p["specs"]["model_id"]) == FarmBotBuilder.MODEL_ID and str(p["type"]) == "plant", "a food plant with the FarmBot model")
	_ok(float(p["specs"]["food_fraction"]) > 0.0, "it grows food")
	_ok(ModelCatalog.find(FarmBotBuilder.MODEL_ID).get("procedural", false) == true, "catalog entry is procedural")
	_ok(PackedSpec.for_model(FarmBotBuilder.MODEL_ID).get("mass_kg", -1.0) > 0.0, "it has a packed spec")


func _has_check(d: Dictionary, word: String) -> bool:
	for c in (d["checks"] as Array):
		if str(c["text"]).contains(word):
			return true
	return false


func _test_builder() -> void:
	var s := FarmBotPresets.spec("genesis_xl")
	var b := FarmBotBuilder.build_node(s)
	root.add_child(b)
	var lay: Dictionary = b.design["layout"]
	var inst := 0
	for c in b.get_node("Crops").get_children():
		inst += (c as MultiMeshInstance3D).multimesh.instance_count
	_ok(inst == int(lay["total"]), "every plant drawn (%d)" % inst)
	b.set_machine(Vector3(1500, 700, -200), "watering", true)
	_near(b.gantry.position.x, 1.5 - 3.0, 1e-6, "the gantry stands at machine X")
	_near(b.cross.position.z, 0.7 - 1.5, 1e-6, "the cross-slide at machine Y")
	_near((b.tools["watering"] as Node3D).position.y, b.tip_y(-200.0), 1e-6, "the mounted tool's tip at machine Z")
	_ok(b.spray.visible, "water shows while watering")
	_near(b.zaxis.position.y, b.tip_y(-200.0) + FarmBotBuilder.TOOL_LEN, 1e-6, "the tool mount sits a tool's length above the tip")
	b.set_machine(FarmBotJobs.park_pos(b.spec), "", false)
	var slot := FarmBotJobs.slot_of(b.spec, "watering")
	_ok((b.tools["watering"] as Node3D).position.is_equal_approx(b.machine_to_local(slot)), "put back, the tool hangs in its slot")
	_ok(not b.spray.visible, "no water parked")
	var soil := float(b.spec["gantry"]["soil_z_mm"])
	_near(b.tip_y(soil), float(b.spec["bed"]["wall_h_m"]) - FarmBotBuilder.SOIL_BELOW_TOP, 1e-6, "Z at soil_z touches the soil")
	_ok(b.tip_y(0.0) < float(b.spec["bed"]["wall_h_m"]) + float(b.spec["gantry"]["clearance_m"]) + 0.2, "the tip at the top of Z is up by the beam")
	_ok((b.get_node("Bed") as MeshInstance3D).mesh.get_surface_count() >= 2, "the bed has walls and soil")
	_ok(b.get_node_or_null("Gantry/CrossSlide/ZAxis") != null, "gantry → cross-slide → Z axis")
	var mi := b.get_node("Gantry/GantryMesh") as MeshInstance3D
	_ok(mi.has_meta("skip_prop_collision"), "moving parts never collide")
	b.queue_free()


## The radial arm over a keyhole bed: geometry, layout, the arms' days, the
## builder.
func _test_radial() -> void:
	var s := FarmBotSpec.resolve(FarmBotPresets.spec("keyhole_dome_20m"))
	_ok(FarmBotGeom.is_radial(s) and FarmBotGeom.arm_count(s) == 3, "the 20 m keyhole preset: radial, three arms")
	# The bed is the greenhouse keyhole, area for area.
	_near(FarmBotSpec.area_m2(s), GrowBed.layout_area_m2({"layout": "keyhole"}), 1e-6, "the same ring beds as the greenhouse keyhole")
	var rr := FarmBotGeom.rail_r(s)
	var sw := FarmBotGeom.sweep(s)
	_near(FarmBotGeom.x_max_mm(s), sw.y * rr * 1000.0, 1e-3, "X runs the rail's arc")
	_ok(sw.x > 0.0 and sw.x + sw.y < TAU, "stopping at the slot, the rail leaves the slot clear")
	_near(FarmBotGeom.arm_angle(s, 0.0), sw.x, 1e-9, "X = 0 is the rail's start")
	var rt := true
	for ang in [0.6, 1.9, 3.1, 4.4, 5.6]:
		for r in [1.5, 4.0, 8.9]:
			var p := Vector2(sin(ang) * r, cos(ang) * r)
			var m := FarmBotGeom.to_machine(s, p.x, p.y)
			if FarmBotGeom.to_bed(s, m.x, m.y).distance_to(p) > 1e-4:
				rt = false
	_ok(rt, "bed -> machine -> bed round trip")
	var full := s.duplicate(true)
	full["keyhole"]["sweep"] = "full"
	_near(FarmBotGeom.sweep(FarmBotSpec.resolve(full)).y, TAU, 1e-5, "bridging the slot, the arm goes all the way round")
	# Layout: every plant in a ring bed, none in the slot or the paths.
	var lay := FarmBotLayout.solve(s)
	var inside := true
	var rings := FarmBotGeom.rings(s)
	for pv in (lay["plants"] as Array):
		var p2 := Vector2(float(pv["x"]), float(pv["z"]))
		var r2 := p2.length()
		var a2 := fposmod(atan2(p2.x, p2.y), TAU)
		var ok := false
		for rv in rings:
			if r2 >= float(rv["r0"]) - 1e-4 and r2 <= float(rv["r1"]) + 1e-4 and a2 >= float(rv["a0"]) - 1e-4 and a2 <= float(rv["a1"]) + 1e-4:
				ok = true
		if not ok:
			inside = false
	_ok(inside and int(lay["total"]) > 2000, "%d plants, every one in a ring bed" % int(lay["total"]))
	var spaced := true
	var secs: Array = lay["sections"]
	for si in [0, secs.size() / 2, secs.size() - 1]:
		var pts: Array = []
		for pv2 in (lay["plants"] as Array):
			if int(pv2["section"]) == si:
				pts.append(Vector2(float(pv2["x"]), float(pv2["z"])))
		var sp := GardenCrops.spacing(str(secs[si]["crop"]))
		for i in pts.size():
			for j in range(i + 1, pts.size()):
				if (pts[i] as Vector2).distance_to(pts[j]) < sp * 0.999:
					spaced = false
	_ok(spaced, "plants on arcs keep their spacing")
	var sq := s.duplicate(true)
	sq["crops"]["packing"] = "square"
	_ok(int(FarmBotLayout.solve(FarmBotSpec.resolve(sq))["total"]) <= int(lay["total"]), "hex holds no fewer than square on arcs")
	var wedges := s.duplicate(true)
	wedges["crops"]["layout"] = "blocks"
	var lw := FarmBotLayout.solve(FarmBotSpec.resolve(wedges))
	var first := str(lw["sections"][0]["crop"])
	var same := 0
	for sv in (lw["sections"] as Array):
		if float(sv["a1"]) < 1.2 and str(sv["crop"]) == first:
			same += 1
	_ok(same >= 3, "wedges: the first crop has the first wedge of every ring")
	# The arms' days.
	var day := FarmBotEconomics.STEADY_FROM_DAY + 3
	var plan := FarmBotJobs.day_plan(s, lay, day, true)
	var arms: Array = plan["arms"]
	_ok(arms.size() == 3, "a schedule per arm")
	var in_sector := true
	var y_ok := true
	var yr := FarmBotGeom.y_range_mm(s)
	for ai in arms.size():
		var xr := FarmBotJobs.arm_range(s, ai)
		for jv in (arms[ai]["jobs"] as Array):
			for sg in (jv["segs"] as Array):
				for pt in [sg["a"], sg["b"]]:
					var v: Vector3 = pt
					if v.x < xr.x - 1.0 or v.x > xr.y + 1.0:
						in_sector = false
					if v.y < yr.x - 1.0 or v.y > yr.y + 1.0:
						y_ok = false
	_ok(in_sector, "every arm stays in its own sector of the rail")
	_ok(y_ok, "the carriage stays on the arm")
	_near(float(plan["water_l"]), float(s["care"]["water_mm_day"]) * FarmBotSpec.area_m2(s), 1.0, "the arms together give the bed its water")
	var one := s.duplicate(true)
	one["keyhole"]["arms"] = 1
	var p1 := FarmBotJobs.day_plan(FarmBotSpec.resolve(one), lay, day, false)
	_ok(float(plan["busy_s"]) < 0.5 * float(p1["busy_s"]), "three arms finish the day in under half one arm's time (%.1f vs %.1f h)" % [
		float(plan["busy_s"]) / 3600.0, float(p1["busy_s"]) / 3600.0])
	_ok(_has_check(FarmBotDesign.solve(FarmBotSpec.resolve(one)), "day"), "one arm on the 20 m keyhole is flagged: its day does not fit")
	var d := FarmBotDesign.solve(s)
	var errs := 0
	for c in (d["checks"] as Array):
		if str(c["level"]) == "error":
			errs += 1
	_ok(errs == 0 and _has_check(d, "arms share"), "three arms fit, and the checks say how they share the rail")
	_ok(FarmBotSpec.kit_price_usd(s) > FarmBotSpec.kit_price_usd(FarmBotSpec.resolve(one)), "every extra arm costs")
	var tool_ok := true
	for ai2 in arms.size():
		var sl := FarmBotJobs.slot_of(s, "watering", ai2)
		var xr2 := FarmBotJobs.arm_range(s, ai2)
		if sl.x < xr2.x or sl.x > xr2.y or absf(sl.y - FarmBotGeom.tool_r(s) * 1000.0) > 1e-3:
			tool_ok = false
	_ok(tool_ok, "each arm's tools hang on the post's ring in its own sector")
	var inner := INF
	for rv2 in rings:
		inner = minf(inner, float(rv2["r0"]))
	_ok(FarmBotGeom.tool_r(s) < inner and FarmBotGeom.tool_r(s) > float(FarmBotGeom.keyhole(s)["centre_r"]) * 0.5,
		"the tool ring is in the path between the basket and the first bed")
	# The builder.
	var b := FarmBotBuilder.build_node(s)
	root.add_child(b)
	_ok(b.arms.size() == 3 and b.get_node_or_null("Arm2/Carriage/ZAxis") != null, "three arms, each arm → carriage → Z axis")
	var target := Vector3(6000.0, 5300.0, -200.0)
	b.set_arm(1, target, "watering", true)
	var e: Dictionary = b.arms[1]
	_near((e["node"] as Node3D).rotation.y, FarmBotGeom.arm_angle(s, 6000.0), 1e-6, "the arm turns to its angle")
	_near((e["carriage"] as Node3D).position.z, 5.3, 1e-6, "the carriage runs out along the arm")
	var chain := (e["node"] as Node3D).transform * (e["carriage"] as Node3D).transform * (e["z"] as Node3D).transform
	var tip_w := chain.origin - Vector3(0.0, FarmBotBuilder.TOOL_LEN, 0.0)
	var want := b.machine_to_local(target)
	_ok(tip_w.distance_to(want) < 1e-3, "the tool tip lands on the machine point in the bed")
	_ok(((e["tools"] as Dictionary)["watering"] as Node3D).position.distance_to(want) < 1e-4 and (e["spray"] as MeshInstance3D).visible,
		"the arm's own nozzle is mounted and spraying")
	var plant: Dictionary = (lay["plants"] as Array)[100]
	var m2 := FarmBotGeom.to_machine(s, float(plant["x"]), float(plant["z"]))
	var lp := b.machine_to_local(Vector3(m2.x, m2.y, -200.0))
	_ok(Vector2(lp.x, lp.z).distance_to(Vector2(float(plant["x"]), float(plant["z"]))) < 1e-3, "a plant's machine point is over the plant")
	_ok(b.get_node("Bed") is MeshInstance3D and (b.get_node("Bed") as MeshInstance3D).mesh.get_surface_count() >= 2, "the keyhole bed is drawn")
	b.queue_free()
