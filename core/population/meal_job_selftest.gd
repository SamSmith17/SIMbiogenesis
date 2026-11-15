extends SceneTree

## Meals as small crew jobs (NPC life pass, Phase 7): CrewJobPlan (the generic
## crew scheduler) and MealJobPlan (a kitchen step as jobs at the stations),
## the camp kitchen's stations, the kitchen recipe's reading, and the rota
## crewing a day's cooking. Offline, deterministic. Carries EXPECTED_CHECKS.
##
##   Godot --headless --path . --script core/population/meal_job_selftest.gd

const EXPECTED_CHECKS := 27

var _checks := 0
var _failed := 0


func _initialize() -> void:
	print("MEAL JOB SELFTEST")
	_test_crew_plan()
	_test_meal_plan()
	_test_progress_map()
	_test_kitchen()
	_test_recipe_and_rota()
	if _checks != EXPECTED_CHECKS:
		_failed += 1
		print("  FAIL: ran %d checks, expected %d (a test function aborted?)" % [_checks, EXPECTED_CHECKS])
	if _failed == 0:
		print("MEAL JOB SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("MEAL JOB SELFTEST FAIL  (%d of %d checks failed)" % [_failed, _checks])
	quit(1 if _failed > 0 else 0)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failed += 1
		push_error("FAIL: %s  %s" % [label, detail])
		print("  FAIL: %s  %s" % [label, detail])


func _sound(tl: Dictionary) -> String:
	var jobs: Array = tl["jobs"]
	for j in jobs:
		if float(j["t0"]) < 0.0:
			return "job %d not scheduled" % int(j["id"])
		for d in j["deps"]:
			if float(j["t0"]) < float(jobs[d]["t1"]) - 1e-6:
				return "job %d starts before its dependency %d ends" % [int(j["id"]), int(d)]
		var n := (j["crew"] as Array).size()
		if bool(j["unattended"]):
			if n != 0:
				return "unattended job %d has a crew" % int(j["id"])
		elif n < maxi(int(j["min"]), 1) or n > int(j["max"]):
			return "job %d crew %d outside %d..%d" % [int(j["id"]), n, int(j["min"]), int(j["max"])]
	for w in tl["workers"]:
		var segs: Array = w["segments"]
		for i in range(1, segs.size()):
			if float(segs[i]["t0"]) < float(segs[i - 1]["t1"]) - 1e-6:
				return "worker %d in two places at %.1f s" % [int(w["id"]), float(segs[i]["t0"])]
	return ""


func _test_crew_plan() -> void:
	var st := MealJobPlan.default_stations()
	for kind in [MealJobPlan.STEP_PREP, MealJobPlan.STEP_COOK, MealJobPlan.STEP_SERVE]:
		var tl := MealJobPlan.build(kind, 32.0, 3)
		var why := _sound(tl)
		_check("%s: every job scheduled, deps kept, crews in range, nobody in two places" % kind,
			why.is_empty() and (tl["blocked"] as Array).is_empty(), why)
	var a := MealJobPlan.build(MealJobPlan.STEP_PREP, 32.0, 3)
	var b := MealJobPlan.build(MealJobPlan.STEP_PREP, 32.0, 3)
	_check("deterministic", str(a["jobs"]) == str(b["jobs"]) and str(a["workers"]) == str(b["workers"]))
	_check("makespan at least the critical path and the work over the crew",
		float(a["makespan"]) >= CrewJobPlan.critical_path(a) - 1e-6
		and float(a["makespan"]) >= float(a["person_s"]) / 3.0 - 1e-6)
	var prev := INF
	var mono := true
	for n in [1, 2, 3, 4]:
		var t := MealJobPlan.build(MealJobPlan.STEP_PREP, 32.0, n)
		if float(t["makespan"]) > prev + 1.0:
			mono = false
		prev = float(t["makespan"])
	_check("more hands never make the prep slower", mono)
	var s1 := CrewJobPlan.state_at(a, float(a["makespan"]) * 0.4)
	var s2 := CrewJobPlan.state_at(a, float(a["makespan"]) * 0.4)
	_check("state_at is a pure function of time", str(s1) == str(s2))
	var at_station := true
	for w in s1["workers"]:
		if str(w["activity"]) != "work":
			continue
		var j: Dictionary = a["jobs"][int(w["job"])]
		var spot: Vector3 = (st[str(j["station"])] as Dictionary)["pos"]
		if Vector2(w["pos"].x, w["pos"].z).distance_to(Vector2(spot.x, spot.z)) > CrewJobPlan.SIDE_STEP_M * 2.0:
			at_station = false
	_check("a worker at work stands at the job's station", at_station)
	var end := CrewJobPlan.state_at(a, float(a["makespan"]) + 1.0)
	_check("at the end every job is done and nobody is working",
		int(end["done"]) == (a["jobs"] as Array).size()
		and (end["workers"] as Array).all(func(w) -> bool: return str(w["activity"]) != "work"))


func _test_meal_plan() -> void:
	_check("step kinds from the recipe's words",
		MealJobPlan.step_kind("prep", "Prep the day's ingredients") == "prep"
		and MealJobPlan.step_kind("serve", "Plate, serve and wash up") == "serve"
		and MealJobPlan.step_kind("cook", "Cook") == "cook" and MealJobPlan.step_kind("x", "Fix the pump") == "")
	_check("a cook per ~12 servings, 1..4", MealJobPlan.crew_for(8.0) == 1 and MealJobPlan.crew_for(32.0) == 3
		and MealJobPlan.crew_for(500.0) == 4)
	var p := MealJobPlan.build(MealJobPlan.STEP_PREP, 32.0, 3, {"person_hours": 1.0})
	_check("the plan's work is the chore's hours exactly", absf(float(p["person_s"]) - 3600.0) < 1e-3,
		"%.2f s" % float(p["person_s"]))
	var kinds: Array = (p["jobs"] as Array).map(func(j): return str(j["kind"]))
	_check("prep: fetch, wash, chop, into the pot", kinds.has("fetch") and kinds.has("wash_veg")
		and kinds.count("chop") == 3 and kinds.has("pot"))
	var chops: Array = (p["jobs"] as Array).filter(func(j): return str(j["kind"]) == "chop")
	var overlap := float(chops[0]["t0"]) < float(chops[1]["t1"]) and float(chops[1]["t0"]) < float(chops[0]["t1"])
	_check("three cooks chop at once", overlap)
	var sv := MealJobPlan.build(MealJobPlan.STEP_SERVE, 32.0, 2)
	var by := {}
	for j in sv["jobs"]:
		by[str(j["kind"])] = j
	_check("serve: the pot goes out before plating, washing up after",
		float(by["plate"]["t0"]) >= float(by["carry_pot"]["t1"]) - 1e-6
		and float(by["wash_up"]["t0"]) >= float(by["plate"]["t1"]) - 1e-6)
	var tools_ok := true
	for j in p["jobs"]:
		var rig := str(j["rig"])
		if rig.is_empty() or not FabContextRig.CLIP_FOR.has(rig) or not FabToolCatalog.TOOLS.has(str(j["tool"])) \
				or NpcAnimClip.load_clip(str(j["clip"])) == null:
			tools_ok = false
	_check("every prep job has a kitchen rig, tool and clip that exist", tools_ok)
	var ck := MealJobPlan.build(MealJobPlan.STEP_COOK, 16.0, 1)
	var sim: Array = (ck["jobs"] as Array).filter(func(j): return bool(j["unattended"]))
	_check("the simmer runs by itself", sim.size() == 1 and (sim[0]["crew"] as Array).is_empty()
		and float(ck["makespan"]) > MealJobPlan.SIMMER_S)


func _test_progress_map() -> void:
	var p := MealJobPlan.build(MealJobPlan.STEP_SERVE, 32.0, 2, {"person_hours": 0.5})
	_check("no work = the start, all the work = the end",
		MealJobPlan.time_for_progress(p, 0.0) < 1.0
		and absf(MealJobPlan.time_for_progress(p, 1.0) - float(p["makespan"])) < 1.0)
	var ok := true
	var prev := -1.0
	for f in [0.1, 0.25, 0.5, 0.75, 0.9]:
		var t := MealJobPlan.time_for_progress(p, f)
		if t < prev:
			ok = false
		prev = t
		if absf(MealJobPlan.work_done_at(p, t) / float(p["person_s"]) - f) > 0.01:
			ok = false
	_check("progress maps onto the time that much work is done, monotone", ok)


func _test_kitchen() -> void:
	var k := CampKitchenBuilder.build_node()
	var st: Dictionary = k.get_meta("stations", {})
	_check("the camp kitchen carries MealJobPlan's stations", str(st) == str(MealJobPlan.default_stations()))
	var ok := true
	for name in ["store", "prep", "stove", "wash"]:
		var p: Vector3 = st[name]["pos"]
		# The counter's near edge (centre z COUNTER_Z, 0.6 deep) 0.2 m in front.
		if absf((MealJobPlan.COUNTER_Z + 0.3) - p.z - (-0.2)) > 0.01:
			ok = false
	_check("cooks stand 0.2 m from the counter's edge (the rigs' reach)", ok)
	var meshes := k.find_children("*", "MeshInstance3D", true, false)
	_check("the kitchen is drawn (%d parts)" % meshes.size(), meshes.size() > 30)
	_check("it packs (curated)", PackedSpec.CURATED_MODELS.has(CampKitchenBuilder.MODEL_ID))
	k.free()


func _test_recipe_and_rota() -> void:
	var info := MealJobPlan.recipe_info({"selected_recipe_id": "meal_prep", "role": "kitchen"})
	_check("meal_prep: 8 servings, a prep and a serve step with crew hours",
		is_equal_approx(float(info["servings"]), 8.0) and (info["steps"] as Array).size() == 2
		and str(info["steps"][0]["kind"]) == "prep" and str(info["steps"][1]["kind"]) == "serve",
		str(info))
	_check("its crew hours", is_equal_approx(float(info["hours"]), 0.75))
	# The rota crews a day's cooking like any recurring job.
	var r := NpcRoutine.default_day()
	var people: Array = []
	for i in 6:
		var id := "k_npc_%d" % i
		people.append({"id": id, "offset_h": 0.0, "persona": NpcPersona.for_id(id), "skills": {}, "worked_h": 0.0})
	var day := 739000
	var items: Array = [{"key": "cook|kit|%d" % day, "kind": "cook", "ref": "kit", "label": "Cook: Kitchen",
		"family": "cook", "day": day, "hours": 1.5, "crew": 3, "min_crew": 1,
		"window": {"start_h": 6.0, "end_h": 20.0}, "skill": "", "priority": 5}]
	var plan := NpcWorkScheduler.plan(items, people, r, day, 1)
	var sh: Dictionary = (plan["shifts"] as Dictionary).get("cook|kit|%d" % day, {})
	_check("the rota names three cooks for the day", (sh.get("agents", []) as Array).size() == 3, str(sh))
	var evs := ScheduledEvents.from_rota(plan, {}, "h")
	_check("the cooking shows on the calendar as a shift", evs.size() == 1 and str(evs[0]["kind"]) == "shift"
		and str(evs[0]["label"]).begins_with("Cook: Kitchen"))
